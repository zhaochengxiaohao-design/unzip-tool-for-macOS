import Darwin
import Foundation

public struct CompressionInputSummary: Equatable, Sendable {
    public let entryCount: Int
    public let totalLogicalSize: Int64
    public let containsSymbolicLinks: Bool
    public let estimatedGenericArchiveSize: Int64
    public let estimatedTarArchiveSize: Int64

    public init(
        entryCount: Int,
        totalLogicalSize: Int64,
        containsSymbolicLinks: Bool,
        estimatedGenericArchiveSize: Int64? = nil,
        estimatedTarArchiveSize: Int64? = nil
    ) {
        self.entryCount = entryCount
        self.totalLogicalSize = totalLogicalSize
        self.containsSymbolicLinks = containsSymbolicLinks
        self.estimatedGenericArchiveSize = estimatedGenericArchiveSize ?? totalLogicalSize
        self.estimatedTarArchiveSize = estimatedTarArchiveSize ?? totalLogicalSize
    }
}

public enum CompressionInputSecurityError: LocalizedError, Equatable, Sendable {
    case inaccessible(String)
    case unsupportedFileType(String)
    case tooManyEntries(Int)
    case pathTooLong(String)
    case sizeOverflow
    case outputInsideInput

    public var errorDescription: String? {
        switch self {
        case .inaccessible(let path):
            return AppLocalization.format("无法安全读取待压缩项目：%@", path)
        case .unsupportedFileType(let path):
            return AppLocalization.format("待压缩项目包含不支持的特殊文件：%@", path)
        case .tooManyEntries(let count):
            return AppLocalization.format("待压缩项目包含 %d 个条目，超过安全上限。", count)
        case .pathTooLong(let path):
            return AppLocalization.format("待压缩项目的路径过长，无法安全处理：%@", path)
        case .sizeOverflow:
            return AppLocalization.text("待压缩项目的总大小无法安全表示。")
        case .outputInsideInput:
            return AppLocalization.text("压缩包不能保存到正在压缩的文件夹内部，请选择其上级目录或其他目录。")
        }
    }
}

public enum CompressionInputSecurity {
    public static let maximumEntryCount = 1_000_000
    public static let maximumPathBytes = 32_768

    public static func validate(
        inputs: [URL],
        outputURL: URL,
        fileManager: FileManager = .default,
        shouldCancel: () -> Bool = { false }
    ) throws -> CompressionInputSummary {
        let outputParent = outputURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        let outputPath = URL(fileURLWithPath: outputParent, isDirectory: true)
            .appendingPathComponent(outputURL.lastPathComponent, isDirectory: false).path
        var entryCount = 0
        var totalLogicalSize: Int64 = 0
        var genericEstimate: Int64 = 0
        var tarEstimate: Int64 = 1_024
        var containsLinks = false

        func checkedAdd(_ value: Int64, to accumulator: inout Int64) throws {
            guard value >= 0 else { throw CompressionInputSecurityError.sizeOverflow }
            let result = accumulator.addingReportingOverflow(value)
            guard !result.overflow else { throw CompressionInputSecurityError.sizeOverflow }
            accumulator = result.partialValue
        }

        func checkedMultiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
            let result = lhs.multipliedReportingOverflow(by: rhs)
            guard lhs >= 0, rhs >= 0, !result.overflow else {
                throw CompressionInputSecurityError.sizeOverflow
            }
            return result.partialValue
        }

        func addEntryEstimate(url: URL, info: FileInfo) throws {
            entryCount += 1
            if entryCount > maximumEntryCount {
                throw CompressionInputSecurityError.tooManyEntries(entryCount)
            }

            let pathByteCount = url.path.utf8.count
            guard pathByteCount <= maximumPathBytes else {
                throw CompressionInputSecurityError.pathTooLong(url.lastPathComponent)
            }
            let pathCost = try checkedMultiply(Int64(pathByteCount), 4)
            try checkedAdd(4_096, to: &genericEstimate)
            try checkedAdd(pathCost, to: &genericEstimate)
            try checkedAdd(2_048, to: &tarEstimate)
            try checkedAdd(pathCost, to: &tarEstimate)

            switch info.kind {
            case .regular:
                try checkedAdd(info.size, to: &totalLogicalSize)
                try checkedAdd(info.size, to: &genericEstimate)
                let rounded = info.size.addingReportingOverflow(511)
                guard !rounded.overflow else { throw CompressionInputSecurityError.sizeOverflow }
                try checkedAdd((rounded.partialValue / 512) * 512, to: &tarEstimate)
            case .symbolicLink:
                containsLinks = true
                try checkedAdd(info.size, to: &genericEstimate)
                try checkedAdd(info.size, to: &tarEstimate)
            case .directory, .unsupported:
                break
            }
        }

        func inspect(_ url: URL) throws -> FileInfo {
            if shouldCancel() { throw ArchiveEngineError.cancelled }
            let info = try fileInfo(at: url)
            try addEntryEstimate(url: url, info: info)
            switch info.kind {
            case .regular:
                guard fileManager.isReadableFile(atPath: url.path) else {
                    throw CompressionInputSecurityError.inaccessible(url.lastPathComponent)
                }
            case .directory:
                guard fileManager.isReadableFile(atPath: url.path) else {
                    throw CompressionInputSecurityError.inaccessible(url.lastPathComponent)
                }
            case .symbolicLink:
                break
            case .unsupported:
                throw CompressionInputSecurityError.unsupportedFileType(url.lastPathComponent)
            }
            return info
        }

        for originalInput in inputs {
            if shouldCancel() { throw ArchiveEngineError.cancelled }
            guard originalInput.isFileURL else {
                throw CompressionInputSecurityError.inaccessible(originalInput.absoluteString)
            }
            let input = originalInput.standardizedFileURL
            let info = try inspect(input)

            if info.kind == .regular {
                let realInput = input.resolvingSymlinksInPath().standardizedFileURL.path
                if realInput == outputPath { throw CompressionInputSecurityError.outputInsideInput }
            }
            guard info.kind == .directory else { continue }

            let realDirectory = input.resolvingSymlinksInPath().standardizedFileURL.path
            if isPath(outputParent, equalToOrInside: realDirectory) {
                throw CompressionInputSecurityError.outputInsideInput
            }

            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: input,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw CompressionInputSecurityError.inaccessible(input.lastPathComponent)
            }
            for case let child as URL in enumerator {
                let childInfo = try inspect(child)
                if childInfo.kind == .symbolicLink { enumerator.skipDescendants() }
            }
            if enumerationError != nil {
                throw CompressionInputSecurityError.inaccessible(input.lastPathComponent)
            }
        }

        return CompressionInputSummary(
            entryCount: entryCount,
            totalLogicalSize: totalLogicalSize,
            containsSymbolicLinks: containsLinks,
            estimatedGenericArchiveSize: genericEstimate,
            estimatedTarArchiveSize: tarEstimate
        )
    }

    private static func isPath(_ path: String, equalToOrInside directory: String) -> Bool {
        if directory == "/" { return path.hasPrefix("/") }
        return path == directory || path.hasPrefix(directory + "/")
    }

    private enum FileKind: Equatable { case regular, directory, symbolicLink, unsupported }
    private struct FileInfo { let kind: FileKind; let size: Int64 }

    private static func fileInfo(at url: URL) throws -> FileInfo {
        var status = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &status)
        }
        guard result == 0, status.st_size >= 0 else {
            throw CompressionInputSecurityError.inaccessible(url.lastPathComponent)
        }
        let kind: FileKind
        switch status.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .unsupported
        }
        return FileInfo(kind: kind, size: Int64(status.st_size))
    }
}
