import Foundation

public enum ArchiveSecurityError: LocalizedError, Equatable {
    case unsafePath(String)
    case unsafeSymbolicLink(String)
    case unsupportedFileType(String)
    case tooManyEntries(Int)
    case expandedSizeOverflow
    case ambiguousListing
    case insufficientSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return AppLocalization.format("压缩包包含可能写出目标目录的路径：%@", path)
        case .unsafeSymbolicLink(let path): return AppLocalization.format("压缩包包含指向目标目录外的符号链接：%@", path)
        case .unsupportedFileType(let path): return AppLocalization.format("压缩包包含不安全的特殊文件：%@", path)
        case .tooManyEntries(let count): return AppLocalization.format("压缩包包含 %d 个条目，超过 100 万条安全上限。", count)
        case .expandedSizeOverflow: return AppLocalization.text("压缩包声明的展开大小超出系统可安全处理的范围。")
        case .ambiguousListing: return AppLocalization.text("压缩包的文件清单存在无法安全解析的换行或缺失条目。")
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
    static let safetyReserve: Int64 = 512 * 1_024 * 1_024

    public static func validateInspection(
        _ inspection: ArchiveInspection,
        shouldCancel: () -> Bool = { false }
    ) throws {
        let observedCount = max(inspection.entryCount, inspection.entries.count)
        if observedCount > maximumEntryCount {
            throw ArchiveSecurityError.tooManyEntries(observedCount)
        }
        if inspection.uncompressedSizeOverflowed {
            throw ArchiveSecurityError.expandedSizeOverflow
        }
        if inspection.listingIsAmbiguous || inspection.entryCount != inspection.entries.count {
            throw ArchiveSecurityError.ambiguousListing
        }

        for entry in inspection.entries {
            if shouldCancel() { throw ArchiveEngineError.cancelled }
            let normalized = entry.path.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            if normalized.hasPrefix("/") || normalized.hasPrefix("~") || normalized.contains("\0") || components.contains("..") {
                throw ArchiveSecurityError.unsafePath(entry.path)
            }
            if normalized.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil {
                throw ArchiveSecurityError.unsafePath(entry.path)
            }
            if let target = entry.symbolicLinkTarget, !target.isEmpty {
                try validateSymbolicLink(entryPath: normalized, target: target)
            }
            if let target = entry.hardLinkTarget, !target.isEmpty {
                try validateHardLink(entryPath: normalized, target: target)
            }
            if isSpecialFile(mode: entry.mode, attributes: entry.attributes)
                || (entry.deviceMajor ?? 0) > 0
                || (entry.deviceMinor ?? 0) > 0 {
                throw ArchiveSecurityError.unsupportedFileType(entry.path)
            }
        }
    }

    public static func validateDiskSpace(for inspection: ArchiveInspection, at destination: URL) throws {
        try validateAdditionalDiskSpace(required: inspection.totalUncompressedSize, at: destination)
    }

    static func validateAdditionalDiskSpace(required: Int64, at destination: URL) throws {
        guard required >= 0 else { throw ArchiveSecurityError.expandedSizeOverflow }
        let available = try availableCapacity(at: destination)
        let requiredWithReserve = required.addingReportingOverflow(safetyReserve)
        let requiredBytes = requiredWithReserve.overflow ? Int64.max : requiredWithReserve.partialValue
        if requiredBytes > available {
            throw ArchiveSecurityError.insufficientSpace(required: requiredBytes, available: available)
        }
    }

    static func availableCapacity(at destination: URL) throws -> Int64 {
        let values = try destination.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        var capacities = [
            values.volumeAvailableCapacityForImportantUsage,
            values.volumeAvailableCapacity.map(Int64.init),
        ].compactMap { $0 }.filter { $0 > 0 }

        let attributes = try FileManager.default.attributesOfFileSystem(forPath: destination.path)
        if let number = attributes[.systemFreeSize] as? NSNumber {
            let available = number.int64Value
            guard available >= 0 else { throw ExtractionSecuritySupportError.capacityUnavailable }
            if available == 0 { return 0 }
            capacities.append(available)
        }
        if let available = capacities.min() { return available }
        throw ExtractionSecuritySupportError.capacityUnavailable
    }

    public static func validateExtractedTree(
        at root: URL,
        allowSymbolicLinks: Bool = true,
        fileManager: FileManager = .default,
        shouldCancel: () -> Bool = { false }
    ) throws {
        if shouldCancel() { throw ArchiveEngineError.cancelled }
        let rootInfo = try SecurePOSIXFileSystem.information(at: root)
        guard rootInfo.kind == .directory else {
            throw ArchiveSecurityError.unsupportedFileType(root.lastPathComponent)
        }

        let resolvedRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
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
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path])
        }

        for case let item as URL in enumerator {
            if shouldCancel() { throw ArchiveEngineError.cancelled }
            let info = try SecurePOSIXFileSystem.information(at: item)
            switch info.kind {
            case .regular, .directory:
                break
            case .symbolicLink:
                enumerator.skipDescendants()
                guard allowSymbolicLinks else {
                    throw ArchiveSecurityError.unsupportedFileType(item.lastPathComponent)
                }
                let itemPath = item.deletingLastPathComponent()
                    .resolvingSymlinksInPath()
                    .appendingPathComponent(item.lastPathComponent)
                    .standardizedFileURL.path
                guard itemPath.hasPrefix(resolvedRootPath + "/") else {
                    throw ArchiveSecurityError.unsafePath(item.lastPathComponent)
                }
                let relativePath = String(itemPath.dropFirst(resolvedRootPath.count + 1))
                let target = try SecurePOSIXFileSystem.symbolicLinkTarget(at: item)
                try validateSymbolicLink(entryPath: relativePath, target: target)

                let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == resolvedRootPath || resolved.hasPrefix(resolvedRootPath + "/") else {
                    throw ArchiveSecurityError.unsafeSymbolicLink(relativePath)
                }
            case .other:
                throw ArchiveSecurityError.unsupportedFileType(item.lastPathComponent)
            }
        }
        if let enumerationError { throw enumerationError }
    }

    private static func validateSymbolicLink(entryPath: String, target: String) throws {
        let normalizedTarget = target.replacingOccurrences(of: "\\", with: "/")
        if normalizedTarget.hasPrefix("/") || normalizedTarget.contains("\0")
            || normalizedTarget.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil {
            throw ArchiveSecurityError.unsafeSymbolicLink(entryPath)
        }
        var entryComponents = entryPath.split(separator: "/")
        if !entryComponents.isEmpty { entryComponents.removeLast() }
        var depth = entryComponents.reduce(into: 0) { count, component in
            if component != "." { count += 1 }
        }
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

    /// TAR hard-link names are archive-root-relative rather than relative to
    /// the link's parent. Conservatively reject every parent component.
    private static func validateHardLink(entryPath: String, target: String) throws {
        let normalizedTarget = target.replacingOccurrences(of: "\\", with: "/")
        let components = normalizedTarget.split(separator: "/", omittingEmptySubsequences: false)
        if normalizedTarget.hasPrefix("/") || normalizedTarget.contains("\0")
            || normalizedTarget.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil
            || components.contains("..") {
            throw ArchiveSecurityError.unsafeSymbolicLink(entryPath)
        }
    }

    private static func isSpecialFile(mode: String?, attributes: String?) -> Bool {
        let modeType = mode?.trimmingCharacters(in: .whitespacesAndNewlines).first
        if let modeType, "pscb".contains(modeType) { return true }

        let attributeType = attributes?.trimmingCharacters(in: .whitespacesAndNewlines).first
        if let attributeType, "pscb".contains(attributeType) { return true }
        return false
    }
}

public enum FileMerger {
    public static func hasCollisions(
        from staging: URL,
        into destination: URL,
        fileManager: FileManager = .default,
        shouldCancel: () -> Bool = { false }
    ) throws -> Bool {
        for item in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            try checkCancellation(shouldCancel)
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if try hasCollision(
                source: item,
                target: target,
                fileManager: fileManager,
                shouldCancel: shouldCancel
            ) { return true }
        }
        return false
    }

    public static func merge(
        from staging: URL,
        into destination: URL,
        policy: CollisionPolicy,
        fileManager: FileManager = .default,
        shouldCancel: () -> Bool = { false }
    ) throws {
        guard policy != .cancel else { throw ArchiveEngineError.cancelled }
        let rollbackRoot = staging.deletingLastPathComponent()
            .appendingPathComponent(".回滚-\(UUID().uuidString)", isDirectory: true)
        try SecurePOSIXFileSystem.createPrivateDirectory(at: rollbackRoot, fileManager: fileManager)

        var undoActions: [UndoMove] = []
        do {
            for item in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                try checkCancellation(shouldCancel)
                let target = destination.appendingPathComponent(item.lastPathComponent)
                try mergeItem(
                    source: item,
                    target: target,
                    policy: policy,
                    rollbackRoot: rollbackRoot,
                    undoActions: &undoActions,
                    fileManager: fileManager,
                    shouldCancel: shouldCancel
                )
            }
            try checkCancellation(shouldCancel)
            // 提交已经完成后，清理失败不能再触发可能不完整的回滚；协调器会再次清理整个私有工作区。
            try? fileManager.removeItem(at: rollbackRoot)
        } catch {
            let originalError = error
            var rollbackErrors: [String] = []
            for action in undoActions.reversed() {
                do {
                    guard try SecurePOSIXFileSystem.informationIfPresent(at: action.currentURL) != nil else {
                        rollbackErrors.append(action.currentURL.path)
                        continue
                    }
                    if try SecurePOSIXFileSystem.informationIfPresent(at: action.originalURL) != nil {
                        if action.currentURL.path.hasPrefix(rollbackRoot.path + "/") {
                            let recoveryName = ".万能解压-恢复-\(UUID().uuidString)-\(action.originalURL.lastPathComponent)"
                            let recovery = action.originalURL.deletingLastPathComponent().appendingPathComponent(recoveryName)
                            let recovered = try SecurePOSIXFileSystem.moveToUniqueDestination(
                                from: action.currentURL,
                                desired: recovery
                            )
                            rollbackErrors.append(recovered.path)
                            continue
                        }
                        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: action.originalURL.path])
                    }
                    try SecurePOSIXFileSystem.moveNoReplace(from: action.currentURL, to: action.originalURL)
                } catch {
                    rollbackErrors.append(action.originalURL.path)
                }
            }
            if rollbackErrors.isEmpty {
                try? fileManager.removeItem(at: rollbackRoot)
            } else {
                let recoveryDetails = Array(rollbackErrors.prefix(2)) + [rollbackRoot.path]
                throw ExtractionSecuritySupportError.rollbackFailed(recoveryDetails.joined(separator: "；"))
            }
            throw originalError
        }
    }

    private struct UndoMove {
        let currentURL: URL
        let originalURL: URL
    }

    private static func hasCollision(
        source: URL,
        target: URL,
        fileManager: FileManager,
        shouldCancel: () -> Bool
    ) throws -> Bool {
        try checkCancellation(shouldCancel)
        guard let targetInfo = try SecurePOSIXFileSystem.informationIfPresent(at: target) else { return false }
        let sourceInfo = try SecurePOSIXFileSystem.information(at: source)
        if sourceInfo.kind == .directory && targetInfo.kind == .directory {
            _ = try SecurePOSIXFileSystem.trustedCanonicalDirectory(target)
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                if try hasCollision(
                    source: child,
                    target: target.appendingPathComponent(child.lastPathComponent),
                    fileManager: fileManager,
                    shouldCancel: shouldCancel
                ) {
                    return true
                }
            }
            return false
        }
        return true
    }

    private static func mergeItem(
        source: URL,
        target: URL,
        policy: CollisionPolicy,
        rollbackRoot: URL,
        undoActions: inout [UndoMove],
        fileManager: FileManager,
        shouldCancel: () -> Bool
    ) throws {
        try checkCancellation(shouldCancel)
        guard let targetInfo = try SecurePOSIXFileSystem.informationIfPresent(at: target) else {
            do {
                try SecurePOSIXFileSystem.moveNoReplace(from: source, to: target)
                undoActions.append(UndoMove(currentURL: target, originalURL: source))
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                try mergeItem(
                    source: source,
                    target: target,
                    policy: policy,
                    rollbackRoot: rollbackRoot,
                    undoActions: &undoActions,
                    fileManager: fileManager,
                    shouldCancel: shouldCancel
                )
            }
            return
        }

        let sourceInfo = try SecurePOSIXFileSystem.information(at: source)
        if sourceInfo.kind == .directory && targetInfo.kind == .directory {
            _ = try SecurePOSIXFileSystem.trustedCanonicalDirectory(target)
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try mergeItem(
                    source: child,
                    target: target.appendingPathComponent(child.lastPathComponent),
                    policy: policy,
                    rollbackRoot: rollbackRoot,
                    undoActions: &undoActions,
                    fileManager: fileManager,
                    shouldCancel: shouldCancel
                )
            }
            return
        }

        switch policy {
        case .overwrite:
            let backup = rollbackRoot.appendingPathComponent(UUID().uuidString, isDirectory: targetInfo.kind == .directory)
            try SecurePOSIXFileSystem.moveNoReplace(from: target, to: backup)
            undoActions.append(UndoMove(currentURL: backup, originalURL: target))
            try checkCancellation(shouldCancel)
            try SecurePOSIXFileSystem.moveNoReplace(from: source, to: target)
            undoActions.append(UndoMove(currentURL: target, originalURL: source))
        case .skip:
            return
        case .keepBoth:
            let uniqueTarget = try SecurePOSIXFileSystem.moveToUniqueDestination(
                from: source,
                desired: target,
                shouldCancel: shouldCancel
            )
            undoActions.append(UndoMove(currentURL: uniqueTarget, originalURL: source))
        case .cancel:
            throw ArchiveEngineError.cancelled
        }
    }

    private static func checkCancellation(_ shouldCancel: () -> Bool) throws {
        if shouldCancel() { throw ArchiveEngineError.cancelled }
    }
}
