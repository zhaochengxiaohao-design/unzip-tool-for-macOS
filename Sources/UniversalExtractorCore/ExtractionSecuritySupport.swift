import Darwin
import Foundation

enum ExtractionSecuritySupportError: LocalizedError {
    case invalidWorkspace(String)
    case unsafeSource(String)
    case tooManyVolumes(Int)
    case sizeOverflow
    case capacityUnavailable
    case quarantineFailed(String)
    case rollbackFailed(String)
    case tooManyCollisions

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace(let path):
            return AppLocalization.format("无法创建安全的临时工作目录：%@", path)
        case .unsafeSource(let path):
            return AppLocalization.format("源压缩包或分卷不是普通文件：%@", path)
        case .tooManyVolumes(let count):
            return AppLocalization.format("检测到 %d 个分卷，超过安全上限。", count)
        case .sizeOverflow:
            return AppLocalization.text("压缩包大小超出系统可安全处理的范围。")
        case .capacityUnavailable:
            return AppLocalization.text("无法可靠读取目标磁盘的可用空间。")
        case .quarantineFailed(let path):
            return AppLocalization.format("无法为解压结果保留 macOS 安全标记：%@", path)
        case .rollbackFailed(let detail):
            return AppLocalization.format("目标目录恢复失败，请检查文件：%@", detail)
        case .tooManyCollisions:
            return AppLocalization.text("目标目录中的同名文件过多，无法选择安全的文件名。")
        }
    }
}

final class ExtractionCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        if isCancelled || Task.isCancelled { throw ArchiveEngineError.cancelled }
    }
}

struct QuarantineMetadata: Sendable {
    let value: Data
}

struct PreparedExtractionSource: Sendable {
    let archiveURL: URL
    let quarantineMetadata: QuarantineMetadata?
}

enum SecurePOSIXFileKind: Equatable {
    case regular
    case directory
    case symbolicLink
    case other(mode_t)
}

struct SecurePOSIXFileInfo {
    let kind: SecurePOSIXFileKind
    let size: Int64
    let owner: uid_t
    let permissions: mode_t
    let identity: SecurePOSIXFileIdentity
}

struct SecurePOSIXFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

enum SecurePOSIXFileSystem {
    /// Ensures no other local user can rename a path component while 7-Zip is
    /// using a pathname. Sticky directories are safe only when owned by root or
    /// by this process; a sticky directory's owner may remove any child entry.
    static func trustedCanonicalDirectory(_ directory: URL) throws -> URL {
        var canonicalBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let canonicalized = directory.path.withCString { path in
            canonicalBuffer.withUnsafeMutableBufferPointer { buffer in
                Darwin.realpath(path, buffer.baseAddress)
            }
        }
        guard canonicalized != nil else {
            throw ExtractionSecuritySupportError.invalidWorkspace(directory.path)
        }
        let canonicalPath = String(cString: canonicalBuffer)
        guard canonicalPath.hasPrefix("/") else {
            throw ExtractionSecuritySupportError.invalidWorkspace(directory.path)
        }
        var components = canonicalPath.split(separator: "/", omittingEmptySubsequences: true)

        while true {
            let currentPath = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
            let current = URL(fileURLWithPath: currentPath, isDirectory: true)
            let info = try information(at: current)
            guard info.kind == .directory else {
                throw ExtractionSecuritySupportError.invalidWorkspace(current.path)
            }
            // A directory owner can chmod the directory and then rename any
            // child, even if its current mode is 0555/0755. Only root and this
            // process's user are trusted owners anywhere in the pathname.
            guard info.owner == 0 || info.owner == geteuid() else {
                throw ExtractionSecuritySupportError.invalidWorkspace(current.path)
            }
            let mutableByOtherUsers = info.permissions & 0o022 != 0
            if mutableByOtherUsers {
                let sticky = info.permissions & 0o1000 != 0
                let trustedStickyOwner = info.owner == 0 || info.owner == geteuid()
                guard sticky && trustedStickyOwner else {
                    throw ExtractionSecuritySupportError.invalidWorkspace(current.path)
                }
            }
            if try containsExtendedAllowACL(at: current) {
                throw ExtractionSecuritySupportError.invalidWorkspace(current.path)
            }

            if components.isEmpty {
                return URL(fileURLWithPath: canonicalPath, isDirectory: true)
            }
            components.removeLast()
        }
    }

    static func information(at url: URL) throws -> SecurePOSIXFileInfo {
        var value = stat()
        let result = url.path.withCString { Darwin.lstat($0, &value) }
        guard result == 0 else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }

        let type = value.st_mode & mode_t(S_IFMT)
        let kind: SecurePOSIXFileKind
        switch type {
        case mode_t(S_IFREG): kind = .regular
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other(type)
        }
        return SecurePOSIXFileInfo(
            kind: kind,
            size: max(Int64(value.st_size), 0),
            owner: value.st_uid,
            permissions: value.st_mode & 0o7777,
            identity: SecurePOSIXFileIdentity(device: value.st_dev, inode: value.st_ino)
        )
    }

    static func informationIfPresent(at url: URL) throws -> SecurePOSIXFileInfo? {
        var value = stat()
        let result = url.path.withCString { Darwin.lstat($0, &value) }
        if result == 0 {
            let type = value.st_mode & mode_t(S_IFMT)
            let kind: SecurePOSIXFileKind
            switch type {
            case mode_t(S_IFREG): kind = .regular
            case mode_t(S_IFDIR): kind = .directory
            case mode_t(S_IFLNK): kind = .symbolicLink
            default: kind = .other(type)
            }
            return SecurePOSIXFileInfo(
                kind: kind,
                size: max(Int64(value.st_size), 0),
                owner: value.st_uid,
                permissions: value.st_mode & 0o7777,
                identity: SecurePOSIXFileIdentity(device: value.st_dev, inode: value.st_ino)
            )
        }
        if errno == ENOENT || errno == ENOTDIR { return nil }
        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }

    static func symbolicLinkTarget(at url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = url.path.withCString { path in
            buffer.withUnsafeMutableBufferPointer { pointer in
                Darwin.readlink(path, pointer.baseAddress!, pointer.count - 1)
            }
        }
        guard count >= 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard count < buffer.count - 1 else {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: url.path])
        }
        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func createPrivateDirectory(at url: URL, fileManager: FileManager) throws {
        _ = fileManager // Kept for source compatibility with existing callers.
        let created = url.path.withCString { Darwin.mkdir($0, 0o700) }
        guard created == 0 else {
            throw ExtractionSecuritySupportError.invalidWorkspace(url.path)
        }
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            _ = url.path.withCString { Darwin.rmdir($0) }
            throw ExtractionSecuritySupportError.invalidWorkspace(url.path)
        }
        var value = stat()
        let valid = Darwin.fchmod(descriptor, 0o700) == 0
            && Darwin.fstat(descriptor, &value) == 0
            && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && value.st_uid == geteuid()
            && value.st_mode & 0o077 == 0
        Darwin.close(descriptor)
        guard valid else {
            _ = url.path.withCString { Darwin.rmdir($0) }
            throw ExtractionSecuritySupportError.invalidWorkspace(url.path)
        }
    }

    static func moveNoReplace(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result != 0 else { return }
        if errno == EEXIST {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    static func moveToUniqueDestination(
        from source: URL,
        desired: URL,
        shouldCancel: () -> Bool = { false }
    ) throws -> URL {
        var candidate = desired
        var number = 2
        for _ in 1...10_000 {
            if shouldCancel() { throw ArchiveEngineError.cancelled }
            do {
                try moveNoReplace(from: source, to: candidate)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                candidate = uniqueCandidate(for: desired, number: number)
                number += 1
            }
        }
        throw ExtractionSecuritySupportError.tooManyCollisions
    }

    static func uniqueCandidate(for desiredURL: URL, number: Int) -> URL {
        let compoundExtensions = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.lzma", ".tgz", ".tbz2", ".txz"]
        let lower = desiredURL.lastPathComponent.lowercased()
        let compound = compoundExtensions.first(where: { lower.hasSuffix($0) })
        let ext = compound.map { String($0.dropFirst()) } ?? desiredURL.pathExtension
        let base: String
        if let compound {
            base = String(desiredURL.lastPathComponent.dropLast(compound.count))
        } else {
            base = ext.isEmpty ? desiredURL.lastPathComponent : desiredURL.deletingPathExtension().lastPathComponent
        }
        let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
        return desiredURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func containsExtendedAllowACL(at url: URL) throws -> Bool {
        errno = 0
        let list = url.path.withCString { Darwin.acl_get_file($0, ACL_TYPE_EXTENDED) }
        guard let list else {
            if errno == ENOTSUP { return false }
            if errno == ENOENT {
                // On macOS an existing object without an extended ACL is also
                // reported as ENOENT. Re-check the object so a real path race
                // still fails closed.
                _ = try information(at: url)
                return false
            }
            throw ExtractionSecuritySupportError.invalidWorkspace(url.path)
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(list)) }

        var entry: acl_entry_t?
        var position = ACL_FIRST_ENTRY
        while Darwin.acl_get_entry(list, Int32(position.rawValue), &entry) == 0 {
            guard let entry else {
                throw ExtractionSecuritySupportError.invalidWorkspace(url.path)
            }
            var tag = ACL_UNDEFINED_TAG
            guard Darwin.acl_get_tag_type(entry, &tag) == 0 else {
                throw ExtractionSecuritySupportError.invalidWorkspace(url.path)
            }
            if tag == ACL_EXTENDED_ALLOW { return true }
            position = ACL_NEXT_ENTRY
        }
        return trueIfACLEnumerationFailed(url)
    }

    private static func trueIfACLEnumerationFailed(_ url: URL) -> Bool {
        // acl_get_entry reports EINVAL when iteration reaches the end on macOS.
        // Any other error is treated as unsafe (fail closed).
        return errno != 0 && errno != EINVAL
    }
}

final class SecureExtractionWorkspace: @unchecked Sendable {
    static let maximumVolumeCount = 10_000

    let rootURL: URL
    let stagingURL: URL
    private let snapshotsURL: URL
    private let fileManager: FileManager
    private let rootIdentity: SecurePOSIXFileIdentity

    init(parent: URL, jobID: UUID, fileManager: FileManager) throws {
        self.fileManager = fileManager
        let resolvedParent = try SecurePOSIXFileSystem.trustedCanonicalDirectory(parent)
        let parentInfo = try SecurePOSIXFileSystem.information(at: resolvedParent)
        guard parentInfo.kind == .directory else {
            throw ExtractionSecuritySupportError.invalidWorkspace(resolvedParent.path)
        }
        rootURL = resolvedParent.appendingPathComponent(".万能解压-工作-\(jobID.uuidString)", isDirectory: true)
        stagingURL = rootURL.appendingPathComponent("解压内容", isDirectory: true)
        snapshotsURL = rootURL.appendingPathComponent("源包快照", isDirectory: true)

        var createdRoot = false
        do {
            try SecurePOSIXFileSystem.createPrivateDirectory(at: rootURL, fileManager: fileManager)
            createdRoot = true
            try SecurePOSIXFileSystem.createPrivateDirectory(at: stagingURL, fileManager: fileManager)
            try SecurePOSIXFileSystem.createPrivateDirectory(at: snapshotsURL, fileManager: fileManager)
            let rootInfo = try SecurePOSIXFileSystem.information(at: rootURL)
            guard rootInfo.kind == .directory,
                  rootInfo.owner == geteuid(),
                  rootInfo.permissions & 0o077 == 0 else {
                throw ExtractionSecuritySupportError.invalidWorkspace(rootURL.path)
            }
            rootIdentity = rootInfo.identity
        } catch {
            if createdRoot { try? fileManager.removeItem(at: rootURL) }
            throw error
        }
    }

    func snapshotArchive(_ source: URL, cancellationToken: ExtractionCancellationToken) throws -> URL {
        try cancellationToken.check()
        try validateRootIdentity()
        let volumes = try relatedVolumes(for: source)
        guard volumes.count <= Self.maximumVolumeCount else {
            throw ExtractionSecuritySupportError.tooManyVolumes(volumes.count)
        }

        var required: Int64 = 0
        for volume in volumes {
            try cancellationToken.check()
            let info = try SecurePOSIXFileSystem.information(at: volume)
            guard info.kind == .regular else {
                throw ExtractionSecuritySupportError.unsafeSource(volume.lastPathComponent)
            }
            let addition = required.addingReportingOverflow(info.size)
            guard !addition.overflow else { throw ExtractionSecuritySupportError.sizeOverflow }
            required = addition.partialValue
        }
        try ArchiveSecurity.validateAdditionalDiskSpace(required: required, at: rootURL)

        for volume in volumes {
            try cancellationToken.check()
            let destination = snapshotsURL.appendingPathComponent(volume.lastPathComponent, isDirectory: false)
            try copyRegularFile(
                from: volume,
                to: destination,
                cancellationToken: cancellationToken
            )
            try cancellationToken.check()
            guard try SecurePOSIXFileSystem.information(at: destination).kind == .regular else {
                throw ExtractionSecuritySupportError.unsafeSource(volume.lastPathComponent)
            }
        }

        let snapshot = snapshotsURL.appendingPathComponent(source.lastPathComponent, isDirectory: false)
        guard try SecurePOSIXFileSystem.information(at: snapshot).kind == .regular else {
            throw ExtractionSecuritySupportError.unsafeSource(source.lastPathComponent)
        }
        return snapshot
    }

    func makeLayerDirectory(depth: Int) throws -> URL {
        try validateRootIdentity()
        let url = rootURL.appendingPathComponent("组合层-\(depth)-\(UUID().uuidString)", isDirectory: true)
        try SecurePOSIXFileSystem.createPrivateDirectory(at: url, fileManager: fileManager)
        return url
    }

    func remove() throws {
        guard let info = try SecurePOSIXFileSystem.informationIfPresent(at: rootURL) else { return }
        guard info.kind == .directory, info.identity == rootIdentity else {
            throw ExtractionSecuritySupportError.invalidWorkspace(rootURL.path)
        }
        try fileManager.removeItem(at: rootURL)
    }

    private func validateRootIdentity() throws {
        let info = try SecurePOSIXFileSystem.information(at: rootURL)
        guard info.kind == .directory,
              info.identity == rootIdentity,
              info.owner == geteuid(),
              info.permissions & 0o077 == 0 else {
            throw ExtractionSecuritySupportError.invalidWorkspace(rootURL.path)
        }
    }

    private func copyRegularFile(
        from source: URL,
        to destination: URL,
        cancellationToken: ExtractionCancellationToken
    ) throws {
        let sourceDescriptor = source.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard sourceDescriptor >= 0 else {
            throw ExtractionSecuritySupportError.unsafeSource(source.lastPathComponent)
        }
        defer { Darwin.close(sourceDescriptor) }

        var initial = stat()
        guard Darwin.fstat(sourceDescriptor, &initial) == 0,
              initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              initial.st_size >= 0 else {
            throw ExtractionSecuritySupportError.unsafeSource(source.lastPathComponent)
        }

        let destinationDescriptor = destination.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard destinationDescriptor >= 0 else {
            throw ExtractionSecuritySupportError.unsafeSource(destination.lastPathComponent)
        }
        var completed = false
        defer {
            Darwin.close(destinationDescriptor)
            if !completed { try? fileManager.removeItem(at: destination) }
        }

        var remaining = Int64(initial.st_size)
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while remaining > 0 {
            try cancellationToken.check()
            let requested = min(buffer.count, Int(remaining))
            let readCount = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, requested)
            }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount > 0 else {
                throw ExtractionSecuritySupportError.unsafeSource(source.lastPathComponent)
            }

            var written = 0
            while written < readCount {
                try cancellationToken.check()
                let writeCount = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress!.advanced(by: written),
                        readCount - written
                    )
                }
                if writeCount < 0 && errno == EINTR { continue }
                guard writeCount > 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
                }
                written += writeCount
            }
            remaining -= Int64(readCount)
        }
        guard Darwin.fsync(destinationDescriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        var final = stat()
        guard Darwin.fstat(sourceDescriptor, &final) == 0,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec else {
            throw ExtractionSecuritySupportError.unsafeSource(source.lastPathComponent)
        }
        completed = true
    }

    private func relatedVolumes(for source: URL) throws -> [URL] {
        let directory = source.deletingLastPathComponent()
        let sourceName = source.lastPathComponent
        let lowerSource = sourceName.lowercased()
        let matcher: (String) -> Bool
        if let groups = Self.capture(lowerSource, pattern: #"^(.*\.part)\d+(\.rar)$"#) {
            let prefix = groups[1]
            let suffix = groups[2]
            matcher = { name in
                Self.matches(name.lowercased(), pattern: "^\(NSRegularExpression.escapedPattern(for: prefix))\\d+\(NSRegularExpression.escapedPattern(for: suffix))$")
            }
        } else if let groups = Self.capture(lowerSource, pattern: #"^(.*\.(?:7z|zip)\.)\d{3,}$"#) {
            let prefix = groups[1]
            matcher = { name in
                Self.matches(name.lowercased(), pattern: "^\(NSRegularExpression.escapedPattern(for: prefix))\\d{3,}$")
            }
        } else if let groups = Self.capture(lowerSource, pattern: #"^(.*\.)\d{3,}$"#) {
            let prefix = groups[1]
            matcher = { name in
                Self.matches(name.lowercased(), pattern: "^\(NSRegularExpression.escapedPattern(for: prefix))\\d{3,}$")
            }
        } else if lowerSource.hasSuffix(".rar") {
            let base = String(lowerSource.dropLast(4))
            matcher = { name in
                let lower = name.lowercased()
                return lower == lowerSource
                    || Self.matches(lower, pattern: "^\(NSRegularExpression.escapedPattern(for: base))\\.r\\d{2,}$")
            }
        } else if lowerSource.hasSuffix(".zip") {
            let base = String(lowerSource.dropLast(4))
            matcher = { name in
                let lower = name.lowercased()
                return lower == lowerSource
                    || Self.matches(lower, pattern: "^\(NSRegularExpression.escapedPattern(for: base))\\.z\\d{2,}$")
            }
        } else {
            matcher = { $0 == sourceName }
        }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ExtractionSecuritySupportError.unsafeSource(sourceName)
        }
        var selected: [URL] = []
        for case let candidate as URL in enumerator where matcher(candidate.lastPathComponent) {
            selected.append(candidate)
            if selected.count > Self.maximumVolumeCount {
                throw ExtractionSecuritySupportError.tooManyVolumes(selected.count)
            }
        }
        if enumerationError != nil {
            throw ExtractionSecuritySupportError.unsafeSource(sourceName)
        }
        if !selected.contains(where: { $0.lastPathComponent == sourceName }) { selected.append(source) }
        return selected.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func capture(_ value: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }
}

enum QuarantinePropagation {
    private static let attributeName = "com.apple.quarantine"

    static func metadata(at source: URL) throws -> QuarantineMetadata? {
        let size = source.path.withCString { path in
            attributeName.withCString { name in
                Darwin.getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }
        if size < 0 {
            if errno == ENOATTR || errno == ENOTSUP { return nil }
            throw ExtractionSecuritySupportError.quarantineFailed(source.path)
        }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in
            source.path.withCString { path in
                attributeName.withCString { name in
                    Darwin.getxattr(path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
        guard read == size else {
            throw ExtractionSecuritySupportError.quarantineFailed(source.path)
        }
        return QuarantineMetadata(value: data)
    }

    static func apply(
        _ metadata: QuarantineMetadata?,
        to root: URL,
        fileManager: FileManager,
        shouldCancel: () -> Bool = { false }
    ) throws {
        guard let metadata else { return }
        if shouldCancel() { throw ArchiveEngineError.cancelled }
        try apply(metadata, to: root)

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ExtractionSecuritySupportError.quarantineFailed(root.path)
        }
        for case let item as URL in enumerator {
            if shouldCancel() { throw ArchiveEngineError.cancelled }
            let info = try SecurePOSIXFileSystem.information(at: item)
            switch info.kind {
            case .regular, .directory:
                try apply(metadata, to: item)
            case .symbolicLink:
                enumerator.skipDescendants()
            case .other:
                throw ArchiveSecurityError.unsupportedFileType(item.lastPathComponent)
            }
        }
        if enumerationError != nil {
            throw ExtractionSecuritySupportError.quarantineFailed(root.path)
        }
    }

    private static func apply(_ metadata: QuarantineMetadata, to url: URL) throws {
        let result = metadata.value.withUnsafeBytes { bytes in
            url.path.withCString { path in
                attributeName.withCString { name in
                    Darwin.setxattr(path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
        if result != 0 {
            throw ExtractionSecuritySupportError.quarantineFailed(url.path)
        }
    }
}
