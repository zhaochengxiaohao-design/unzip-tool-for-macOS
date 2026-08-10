import Darwin
import Foundation

enum CompressionPublicationError: LocalizedError {
    case unsafeDestination(String)
    case invalidArchive(String)
    case publicationFailed(String)
    case tooManyCollisions

    var errorDescription: String? {
        switch self {
        case .unsafeDestination(let path):
            return AppLocalization.format("无法在目标位置创建安全的压缩工作目录：%@", path)
        case .invalidArchive(let path):
            return AppLocalization.format("压缩引擎未生成可安全发布的普通文件：%@", path)
        case .publicationFailed(let detail):
            return AppLocalization.format("无法安全保存压缩包：%@", detail)
        case .tooManyCollisions:
            return AppLocalization.text("目标目录中的同名文件过多，无法选择安全的文件名。")
        }
    }
}

/// Keeps incomplete archives private and publishes a verified regular file with
/// a no-replace rename on the destination volume.
final class SecureCompressionWorkspace {
    let rootURL: URL
    let archiveURL: URL

    private let fileManager: FileManager
    private let format: CompressionFormat
    private let rootIdentity: FileIdentity
    private let destinationDirectory: URL

    init(
        destinationDirectory: URL,
        archiveFileName: String,
        format: CompressionFormat,
        fileManager: FileManager
    ) throws {
        self.fileManager = fileManager
        self.format = format

        let parent = try SecurePOSIXFileSystem.trustedCanonicalDirectory(destinationDirectory)
        self.destinationDirectory = parent
        let parentMetadata = try Self.metadata(at: parent)
        guard parentMetadata.kind == .directory else {
            throw CompressionPublicationError.unsafeDestination(parent.path)
        }
        let root = parent.appendingPathComponent(".万能解压-压缩-\(UUID().uuidString)", isDirectory: true)
        let createdMetadata: Metadata
        var createdRoot = false
        do {
            try SecurePOSIXFileSystem.createPrivateDirectory(at: root, fileManager: fileManager)
            createdRoot = true
            createdMetadata = try Self.metadata(at: root)
            guard createdMetadata.kind == .directory,
                  createdMetadata.owner == geteuid(),
                  createdMetadata.permissions & 0o077 == 0 else {
                throw CompressionPublicationError.unsafeDestination(root.path)
            }
        } catch {
            if createdRoot { try? fileManager.removeItem(at: root) }
            throw error
        }

        rootURL = root
        archiveURL = root.appendingPathComponent(archiveFileName, isDirectory: false)
        rootIdentity = createdMetadata.identity
    }

    func publish(to desiredURL: URL) throws -> URL {
        try validateRootIdentity()
        let archiveMetadata = try Self.metadata(at: archiveURL)
        guard archiveMetadata.kind == .regular, archiveMetadata.owner == geteuid() else {
            throw CompressionPublicationError.invalidArchive(archiveURL.lastPathComponent)
        }
        try Self.synchronizeRegularFile(at: archiveURL, expectedIdentity: archiveMetadata.identity)

        let canonicalDesired = destinationDirectory.appendingPathComponent(
            desiredURL.lastPathComponent,
            isDirectory: false
        )
        for sequence in 1...10_000 {
            if Task.isCancelled { throw ArchiveEngineError.cancelled }
            let candidate = candidateURL(for: canonicalDesired, sequence: sequence)
            let result = archiveURL.path.withCString { sourcePath in
                candidate.path.withCString { destinationPath in
                    Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 {
                try Self.verifyIdentity(archiveMetadata.identity, at: candidate)
                return candidate
            }
            if errno == EEXIST { continue }

            // Some external file systems do not implement renamex_np flags. A
            // hard-link publication is also exclusive and exposes only the
            // already-complete archive.
            if errno == ENOTSUP || errno == EINVAL {
                let linkResult = archiveURL.path.withCString { sourcePath in
                    candidate.path.withCString { destinationPath in
                        Darwin.link(sourcePath, destinationPath)
                    }
                }
                if linkResult == 0 {
                    _ = archiveURL.path.withCString { Darwin.unlink($0) }
                    try Self.verifyIdentity(archiveMetadata.identity, at: candidate)
                    return candidate
                }
                if errno == EEXIST { continue }
            }

            let message = String(cString: strerror(errno))
            throw CompressionPublicationError.publicationFailed(message)
        }
        throw CompressionPublicationError.tooManyCollisions
    }

    func remove() {
        guard (try? Self.metadata(at: rootURL).identity) == rootIdentity else { return }
        try? fileManager.removeItem(at: rootURL)
    }

    private func candidateURL(for desiredURL: URL, sequence: Int) -> URL {
        guard sequence > 1 else { return desiredURL }
        let suffix = ".\(format.fileExtension)"
        let name = desiredURL.lastPathComponent
        let base = name.lowercased().hasSuffix(suffix.lowercased())
            ? String(name.dropLast(suffix.count))
            : desiredURL.deletingPathExtension().lastPathComponent
        return desiredURL.deletingLastPathComponent()
            .appendingPathComponent("\(base) \(sequence)\(suffix)", isDirectory: false)
    }

    private enum FileKind { case regular, directory, symbolicLink, other }
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }
    private struct Metadata {
        let kind: FileKind
        let owner: uid_t
        let permissions: mode_t
        let identity: FileIdentity
    }

    private static func fileKind(at url: URL) throws -> FileKind {
        try metadata(at: url).kind
    }

    private func validateRootIdentity() throws {
        guard try Self.metadata(at: rootURL).identity == rootIdentity else {
            throw CompressionPublicationError.unsafeDestination(rootURL.path)
        }
    }

    private static func synchronizeRegularFile(at url: URL, expectedIdentity: FileIdentity) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw CompressionPublicationError.invalidArchive(url.lastPathComponent) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              FileIdentity(device: status.st_dev, inode: status.st_ino) == expectedIdentity,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              Darwin.fsync(descriptor) == 0 else {
            throw CompressionPublicationError.invalidArchive(url.lastPathComponent)
        }
    }

    private static func verifyIdentity(_ identity: FileIdentity, at url: URL) throws {
        guard try metadata(at: url).identity == identity else {
            throw CompressionPublicationError.publicationFailed(
                AppLocalization.text("已发布文件的身份意外发生变化。")
            )
        }
    }

    private static func metadata(at url: URL) throws -> Metadata {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        guard result == 0 else {
            throw CompressionPublicationError.unsafeDestination(url.path)
        }
        let kind: FileKind
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): kind = .regular
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }
        return Metadata(
            kind: kind,
            owner: status.st_uid,
            permissions: status.st_mode & 0o7777,
            identity: FileIdentity(device: status.st_dev, inode: status.st_ino)
        )
    }
}
