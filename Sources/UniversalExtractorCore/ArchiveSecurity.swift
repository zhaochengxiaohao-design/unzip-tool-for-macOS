import Foundation

public enum ArchiveSecurityError: LocalizedError, Equatable {
    case unsafePath(String)
    case unsafeSymbolicLink(String)
    case unsupportedFileType(String)
    case tooManyEntries(Int)
    case insufficientSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return AppLocalization.format("压缩包包含可能写出目标目录的路径：%@", path)
        case .unsafeSymbolicLink(let path): return AppLocalization.format("压缩包包含指向目标目录外的符号链接：%@", path)
        case .unsupportedFileType(let path): return AppLocalization.format("压缩包包含不安全的特殊文件：%@", path)
        case .tooManyEntries(let count): return AppLocalization.format("压缩包包含 %d 个条目，超过 100 万条安全上限。", count)
        case .insufficientSpace(let required, let available):
            return AppLocalization.format(
                "磁盘空间不足，需要约 %@，当前可用 %@。",
                ByteCountFormatter.string(fromByteCount: required, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            )
        }
    }
}

public enum ArchiveSecurity {
    public static let maximumEntryCount = 1_000_000
    private static let safetyReserve: Int64 = 100 * 1_024 * 1_024

    public static func validateInspection(_ inspection: ArchiveInspection) throws {
        if inspection.entries.count > maximumEntryCount {
            throw ArchiveSecurityError.tooManyEntries(inspection.entries.count)
        }
        for entry in inspection.entries {
            let normalized = entry.path.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            if normalized.hasPrefix("/") || normalized.hasPrefix("~") || normalized.contains("\0") || components.contains("..") {
                throw ArchiveSecurityError.unsafePath(entry.path)
            }
            if normalized.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil {
                throw ArchiveSecurityError.unsafePath(entry.path)
            }
            if let target = entry.symbolicLinkTarget {
                try validateSymbolicLink(entryPath: normalized, target: target)
            }
        }
    }

    public static func validateDiskSpace(for inspection: ArchiveInspection, at destination: URL) throws {
        guard inspection.totalUncompressedSize > 0 else { return }
        let values = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let required = inspection.totalUncompressedSize.addingReportingOverflow(safetyReserve)
        let requiredBytes = required.overflow ? Int64.max : required.partialValue
        if requiredBytes > available {
            throw ArchiveSecurityError.insufficientSpace(required: requiredBytes, available: available)
        }
    }

    public static func validateExtractedTree(at root: URL, fileManager: FileManager = .default) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { return }

        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
                    throw ArchiveSecurityError.unsafeSymbolicLink(item.lastPathComponent)
                }
            } else if values.isRegularFile != true && values.isDirectory != true {
                throw ArchiveSecurityError.unsupportedFileType(item.lastPathComponent)
            }
        }
    }

    private static func validateSymbolicLink(entryPath: String, target: String) throws {
        let normalizedTarget = target.replacingOccurrences(of: "\\", with: "/")
        if normalizedTarget.hasPrefix("/") || normalizedTarget.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil {
            throw ArchiveSecurityError.unsafeSymbolicLink(entryPath)
        }
        var depth = max(entryPath.split(separator: "/").count - 1, 0)
        for part in normalizedTarget.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                depth -= 1
                if depth < 0 { throw ArchiveSecurityError.unsafeSymbolicLink(entryPath) }
            } else {
                depth += 1
            }
        }
    }
}

public enum FileMerger {
    public static func hasCollisions(from staging: URL, into destination: URL, fileManager: FileManager = .default) throws -> Bool {
        for item in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if try hasCollision(source: item, target: target, fileManager: fileManager) { return true }
        }
        return false
    }

    public static func merge(from staging: URL, into destination: URL, policy: CollisionPolicy, fileManager: FileManager = .default) throws {
        guard policy != .cancel else { throw ArchiveEngineError.cancelled }
        for item in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            try mergeItem(source: item, target: target, policy: policy, fileManager: fileManager)
        }
    }

    private static func hasCollision(source: URL, target: URL, fileManager: FileManager) throws -> Bool {
        guard fileManager.fileExists(atPath: target.path) else { return false }
        let sourceIsDirectory = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        let targetIsDirectory = (try target.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        if sourceIsDirectory && targetIsDirectory {
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
                if try hasCollision(source: child, target: target.appendingPathComponent(child.lastPathComponent), fileManager: fileManager) {
                    return true
                }
            }
            return false
        }
        return true
    }

    private static func mergeItem(source: URL, target: URL, policy: CollisionPolicy, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: target.path) else {
            try fileManager.moveItem(at: source, to: target)
            return
        }

        let sourceIsDirectory = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        let targetIsDirectory = (try target.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        if sourceIsDirectory && targetIsDirectory {
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
                try mergeItem(source: child, target: target.appendingPathComponent(child.lastPathComponent), policy: policy, fileManager: fileManager)
            }
            try? fileManager.removeItem(at: source)
            return
        }

        switch policy {
        case .overwrite:
            try fileManager.removeItem(at: target)
            try fileManager.moveItem(at: source, to: target)
        case .skip:
            return
        case .keepBoth:
            try fileManager.moveItem(at: source, to: ArchiveUtilities.uniqueURL(for: target, fileManager: fileManager))
        case .cancel:
            throw ArchiveEngineError.cancelled
        }
    }
}
