import Foundation
import Darwin
import UniversalExtractorCore

private var passed = 0

private func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try condition() else {
        FileHandle.standardError.write(Data("✗ \(name)\n".utf8))
        exit(1)
    }
    passed += 1
    print("✓ \(name)")
}

do {
    try check(ArchiveUtilities.outputBaseName(for: URL(fileURLWithPath: "/tmp/photos.tar.gz")) == "photos", "复合扩展名")
    try check(ArchiveUtilities.outputBaseName(for: URL(fileURLWithPath: "/tmp/backup.7z.001")) == "backup", "7Z 分卷命名")
    try check(ArchiveUtilities.outputBaseName(for: URL(fileURLWithPath: "/tmp/movie.part03.rar")) == "movie", "RAR 分卷命名")
    try check(ArchiveUtilities.outputBaseName(for: URL(fileURLWithPath: "/tmp/资料.zip")) == "资料", "中文文件名")
    try check(ArchiveUtilities.archiveFileName(baseName: "资料.zip", format: .tarGzip) == "资料.tar.gz", "压缩格式扩展名替换")
    try check(ArchiveUtilities.archiveFileName(baseName: "backup", format: .sevenZip) == "backup.7z", "压缩格式扩展名追加")
    try check(ArchiveUtilities.sanitizedArchiveName("../escape") == nil, "压缩包名称路径拦截")
    try check(CompressionFormat.gzip.requiresSingleRegularFile && !CompressionFormat.tarGzip.requiresSingleRegularFile, "单文件压缩格式约束")

    let listing = """
    Path = sample.zip
    Type = zip
    Physical Size = 321

    ----------
    Path = folder/readme.txt
    Size = 100
    Attributes = A
    Encrypted = -

    Path = secret.txt
    Size = 220
    Attributes = A
    Encrypted = +
    """
    let parsed = SevenZipEngine.parseTechnicalListing(listing)
    try check(
        parsed.format == "zip"
            && parsed.totalUncompressedSize == 320
            && parsed.entryCount == 2
            && parsed.entries.count == 2
            && !parsed.hasUnknownEntrySizes
            && !parsed.uncompressedSizeOverflowed
            && parsed.encrypted,
        "7-Zip 技术列表解析"
    )

    let unknownSizeListing = """
    Path = unknown.zip
    Type = zip

    ----------
    Path = known.txt
    Size = 4
    Attributes = A

    Path = unknown.bin
    Attributes = A
    """
    let unknownSize = SevenZipEngine.parseTechnicalListing(unknownSizeListing)
    try check(
        unknownSize.entryCount == 2
            && unknownSize.totalUncompressedSize == 4
            && unknownSize.entries[1].size == nil
            && unknownSize.hasUnknownEntrySizes
            && !unknownSize.uncompressedSizeOverflowed,
        "未知展开大小保留并标记"
    )

    let overflowingListing = """
    Path = overflow.7z
    Type = 7z

    ----------
    Path = maximum.bin
    Size = 9223372036854775807
    Attributes = A

    Path = overflow.bin
    Size = 1
    Attributes = A
    """
    let overflowing = SevenZipEngine.parseTechnicalListing(overflowingListing)
    try check(
        overflowing.entryCount == 2
            && overflowing.totalUncompressedSize == Int64.max
            && overflowing.uncompressedSizeOverflowed,
        "展开大小整数溢出标记"
    )
    var rejectedOverflow = false
    do {
        try ArchiveSecurity.validateInspection(overflowing)
    } catch ArchiveSecurityError.expandedSizeOverflow {
        rejectedOverflow = true
    }
    try check(rejectedOverflow, "展开大小溢出拦截")

    let duplicateFieldListing = """
    Path = ambiguous.zip
    Type = zip

    ----------
    Path = innocent.txt
    Path = ../replacement.txt
    Size = 1
    Attributes = A
    """
    let duplicateFieldInspection = SevenZipEngine.parseTechnicalListing(duplicateFieldListing)
    try check(duplicateFieldInspection.listingIsAmbiguous, "重复技术列表字段标记为歧义")
    var rejectedAmbiguousListing = false
    do {
        try ArchiveSecurity.validateInspection(duplicateFieldInspection)
    } catch ArchiveSecurityError.ambiguousListing {
        rejectedAmbiguousListing = true
    }
    try check(rejectedAmbiguousListing, "重复技术列表字段按失败关闭")

    let traversal = ArchiveInspection(format: "zip", physicalSize: 10, totalUncompressedSize: 1, encrypted: false, entries: [
        ArchiveEntry(path: "../escape.txt", size: 1, attributes: nil, symbolicLinkTarget: nil)
    ])
    var rejectedTraversal = false
    do { try ArchiveSecurity.validateInspection(traversal) } catch { rejectedTraversal = true }
    try check(rejectedTraversal, "路径穿越拦截")

    let absolute = ArchiveInspection(format: "zip", physicalSize: 10, totalUncompressedSize: 1, encrypted: false, entries: [
        ArchiveEntry(path: "/tmp/escape.txt", size: 1, attributes: nil, symbolicLinkTarget: nil)
    ])
    var rejectedAbsolute = false
    do { try ArchiveSecurity.validateInspection(absolute) } catch { rejectedAbsolute = true }
    try check(rejectedAbsolute, "绝对路径拦截")

    let dottedLinkEscape = ArchiveInspection(
        format: "tar",
        physicalSize: 10,
        totalUncompressedSize: 0,
        encrypted: false,
        entries: [
            ArchiveEntry(
                path: "folder/./link",
                size: 0,
                attributes: "L",
                symbolicLinkTarget: "../../escape"
            )
        ]
    )
    var rejectedDottedLinkEscape = false
    do {
        try ArchiveSecurity.validateInspection(dottedLinkEscape)
    } catch ArchiveSecurityError.unsafeSymbolicLink(_) {
        rejectedDottedLinkEscape = true
    }
    try check(rejectedDottedLinkEscape, "带点路径不能掩盖符号链接越界")

    let hardLinkEscape = ArchiveInspection(
        format: "tar",
        physicalSize: 10,
        totalUncompressedSize: 0,
        encrypted: false,
        entries: [
            ArchiveEntry(
                path: "folder/link",
                size: 0,
                attributes: "A",
                symbolicLinkTarget: nil,
                hardLinkTarget: "../escape"
            )
        ]
    )
    var rejectedHardLinkEscape = false
    do {
        try ArchiveSecurity.validateInspection(hardLinkEscape)
    } catch ArchiveSecurityError.unsafeSymbolicLink(_) {
        rejectedHardLinkEscape = true
    }
    try check(rejectedHardLinkEscape, "硬链接目标按归档根目录限制")

    let specialArchiveEntry = ArchiveInspection(format: "tar", physicalSize: 10, totalUncompressedSize: 0, encrypted: false, entries: [
        ArchiveEntry(path: "pipe", size: 0, attributes: nil, symbolicLinkTarget: nil, mode: "prw-------")
    ])
    var rejectedSpecialArchiveEntry = false
    do {
        try ArchiveSecurity.validateInspection(specialArchiveEntry)
    } catch ArchiveSecurityError.unsupportedFileType("pipe") {
        rejectedSpecialArchiveEntry = true
    }
    try check(rejectedSpecialArchiveEntry, "压缩包特殊文件条目拦截")

    let safe = ArchiveInspection(format: "7z", physicalSize: 10, totalUncompressedSize: 1, encrypted: false, entries: [
        ArchiveEntry(path: "资料/照片 1.jpg", size: 1, attributes: "A", symbolicLinkTarget: nil),
        ArchiveEntry(path: "资料/link", size: 0, attributes: "L", symbolicLinkTarget: "照片 1.jpg")
    ])
    try ArchiveSecurity.validateInspection(safe)
    try check(true, "安全相对路径")

    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }

    let volumeSamples = root.appendingPathComponent("volume-names", isDirectory: true)
    try manager.createDirectory(at: volumeSamples, withIntermediateDirectories: false)
    let genericFirst = volumeSamples.appendingPathComponent("generic.001")
    let genericLater = volumeSamples.appendingPathComponent("generic.002")
    let legacyRARFirst = volumeSamples.appendingPathComponent("legacy.rar")
    let legacyRARLater = volumeSamples.appendingPathComponent("legacy.r03")
    let legacyZIPFirst = volumeSamples.appendingPathComponent("legacy.zip")
    let legacyZIPLater = volumeSamples.appendingPathComponent("legacy.z04")
    for sample in [
        genericFirst, genericLater, legacyRARFirst,
        legacyRARLater, legacyZIPFirst, legacyZIPLater,
    ] {
        try Data().write(to: sample)
    }
    try check(
        try ArchiveUtilities.normalizedFirstVolume(for: genericLater) == genericFirst,
        "通用数字分卷定位首卷"
    )
    try check(
        try ArchiveUtilities.normalizedFirstVolume(for: legacyRARLater) == legacyRARFirst,
        "旧式 RAR 分卷定位主卷"
    )
    try check(
        try ArchiveUtilities.normalizedFirstVolume(for: legacyZIPLater) == legacyZIPFirst,
        "经典 ZIP 分卷定位主卷"
    )

    let fifo = root.appendingPathComponent("不可信管道")
    let fifoResult = fifo.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.mkfifo(path, 0o600)
    }
    try check(fifoResult == 0, "创建特殊输入样本")
    var rejectedSpecialInput = false
    do {
        _ = try CompressionInputSecurity.validate(
            inputs: [fifo],
            outputURL: root.appendingPathComponent("special.7z")
        )
    } catch CompressionInputSecurityError.unsupportedFileType {
        rejectedSpecialInput = true
    }
    try check(rejectedSpecialInput, "压缩特殊输入文件拦截")

    let directTree = root.appendingPathComponent("direct-tree", isDirectory: true)
    try manager.createDirectory(at: directTree, withIntermediateDirectories: false)
    try Data("inside".utf8).write(to: directTree.appendingPathComponent("inside.txt"))
    try manager.createSymbolicLink(
        atPath: directTree.appendingPathComponent("inside-link").path,
        withDestinationPath: "inside.txt"
    )
    var directModeRejectedLink = false
    do {
        try ArchiveSecurity.validateExtractedTree(at: directTree, allowSymbolicLinks: false)
    } catch ArchiveSecurityError.unsupportedFileType("inside-link") {
        directModeRejectedLink = true
    }
    try check(directModeRejectedLink, "直接解压模式拒绝符号链接")

    let estimateDirectory = root.appendingPathComponent("estimate-inputs", isDirectory: true)
    try manager.createDirectory(at: estimateDirectory, withIntermediateDirectories: false)
    let emptyDirectory = estimateDirectory.appendingPathComponent("empty-directory", isDirectory: true)
    let emptyFile = estimateDirectory.appendingPathComponent("e")
    let longEmptyFile = estimateDirectory.appendingPathComponent("long-" + String(repeating: "x", count: 200))
    try manager.createDirectory(at: emptyDirectory, withIntermediateDirectories: false)
    try Data().write(to: emptyFile)
    try Data().write(to: longEmptyFile)
    let estimateInputs = [emptyDirectory, emptyFile, longEmptyFile]
    let estimateSummary = try CompressionInputSecurity.validate(
        inputs: estimateInputs,
        outputURL: root.appendingPathComponent("estimated.7z")
    )
    let estimatedPathBytes = estimateInputs.reduce(Int64(0)) { partial, url in
        partial + Int64(url.path.utf8.count) * 4
    }
    try check(
        estimateSummary.entryCount == 3 && estimateSummary.totalLogicalSize == 0,
        "空文件和空目录仍计入压缩条目"
    )
    try check(
        estimateSummary.estimatedGenericArchiveSize == 3 * 4_096 + estimatedPathBytes,
        "通用压缩估算包含每条目与长路径开销"
    )
    try check(
        estimateSummary.estimatedTarArchiveSize == 1_024 + 3 * 2_048 + estimatedPathBytes,
        "TAR 估算包含结束块、每条目与长路径开销"
    )

    try check(ArchivePasswordPolicy.isValid("安全 Password 123!"), "安全密码规则")
    try check(!ArchivePasswordPolicy.isValid("line1\nline2"), "密码换行拦截")
    try check(!ArchivePasswordPolicy.isValid("nul\0suffix"), "密码 NUL 拦截")
    try check(!ArchivePasswordPolicy.isValid(String(repeating: "a", count: 257)), "超长密码拦截")

    let sourceFile = staging.appendingPathComponent("readme.txt")
    let existingFile = destination.appendingPathComponent("readme.txt")
    try Data("new".utf8).write(to: sourceFile)
    try Data("old".utf8).write(to: existingFile)
    try check(FileMerger.hasCollisions(from: staging, into: destination), "重名检测")
    try FileMerger.merge(from: staging, into: destination, policy: .keepBoth)
    try check(String(contentsOf: existingFile, encoding: .utf8) == "old", "保留原文件")
    try check(String(contentsOf: destination.appendingPathComponent("readme 2.txt"), encoding: .utf8) == "new", "新文件自动改名")

    let overwriteRoot = root.appendingPathComponent("overwrite-rollback", isDirectory: true)
    let overwriteStaging = overwriteRoot.appendingPathComponent("staging", isDirectory: true)
    let overwriteDestination = overwriteRoot.appendingPathComponent("destination", isDirectory: true)
    try manager.createDirectory(at: overwriteStaging, withIntermediateDirectories: true)
    try manager.createDirectory(at: overwriteDestination, withIntermediateDirectories: true)
    let overwriteSource = overwriteStaging.appendingPathComponent("collision.txt")
    let overwriteExisting = overwriteDestination.appendingPathComponent("collision.txt")
    try Data("replacement".utf8).write(to: overwriteSource)
    try Data("original".utf8).write(to: overwriteExisting)
    var overwriteChecks = 0
    var overwriteCancelled = false
    do {
        try FileMerger.merge(
            from: overwriteStaging,
            into: overwriteDestination,
            policy: .overwrite,
            shouldCancel: {
                overwriteChecks += 1
                return overwriteChecks >= 3
            }
        )
    } catch ArchiveEngineError.cancelled {
        overwriteCancelled = true
    }
    let overwriteRollbackArtifacts = try manager.contentsOfDirectory(
        at: overwriteRoot,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(".回滚-") }
    try check(
        overwriteCancelled
            && String(contentsOf: overwriteExisting, encoding: .utf8) == "original"
            && String(contentsOf: overwriteSource, encoding: .utf8) == "replacement"
            && overwriteRollbackArtifacts.isEmpty,
        "覆盖合并中途取消完整回滚"
    )

    let keepBothRoot = root.appendingPathComponent("keep-both-rollback", isDirectory: true)
    let keepBothStaging = keepBothRoot.appendingPathComponent("staging", isDirectory: true)
    let keepBothDestination = keepBothRoot.appendingPathComponent("destination", isDirectory: true)
    try manager.createDirectory(at: keepBothStaging, withIntermediateDirectories: true)
    try manager.createDirectory(at: keepBothDestination, withIntermediateDirectories: true)
    let keepBothSource = keepBothStaging.appendingPathComponent("collision.txt")
    let keepBothExisting = keepBothDestination.appendingPathComponent("collision.txt")
    try Data("second".utf8).write(to: keepBothSource)
    try Data("first".utf8).write(to: keepBothExisting)
    var keepBothChecks = 0
    var keepBothCancelled = false
    do {
        try FileMerger.merge(
            from: keepBothStaging,
            into: keepBothDestination,
            policy: .keepBoth,
            shouldCancel: {
                keepBothChecks += 1
                return keepBothChecks >= 3
            }
        )
    } catch ArchiveEngineError.cancelled {
        keepBothCancelled = true
    }
    let keepBothNames = try manager.contentsOfDirectory(atPath: keepBothDestination.path)
    let keepBothRollbackArtifacts = try manager.contentsOfDirectory(
        at: keepBothRoot,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(".回滚-") }
    try check(
        keepBothCancelled
            && keepBothNames == ["collision.txt"]
            && String(contentsOf: keepBothExisting, encoding: .utf8) == "first"
            && String(contentsOf: keepBothSource, encoding: .utf8) == "second"
            && keepBothRollbackArtifacts.isEmpty,
        "保留两者合并中途取消完整回滚"
    )

    let unsafeMergeRoot = root.appendingPathComponent("unsafe-target-merge", isDirectory: true)
    let unsafeMergeStaging = unsafeMergeRoot.appendingPathComponent("staging", isDirectory: true)
    let unsafeMergeDestination = unsafeMergeRoot.appendingPathComponent("destination", isDirectory: true)
    let unsafeSourceDirectory = unsafeMergeStaging.appendingPathComponent("shared-name", isDirectory: true)
    let unsafeTargetDirectory = unsafeMergeDestination.appendingPathComponent("shared-name", isDirectory: true)
    try manager.createDirectory(at: unsafeSourceDirectory, withIntermediateDirectories: true)
    try manager.createDirectory(at: unsafeTargetDirectory, withIntermediateDirectories: true)
    let privatePayload = unsafeSourceDirectory.appendingPathComponent("private.txt")
    try Data("must-not-enter-untrusted-directory".utf8).write(to: privatePayload)
    guard Darwin.chmod(unsafeTargetDirectory.path, 0o777) == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
    var rejectedUnsafeTargetDirectory = false
    do {
        try FileMerger.merge(
            from: unsafeMergeStaging,
            into: unsafeMergeDestination,
            policy: .keepBoth
        )
    } catch {
        rejectedUnsafeTargetDirectory = true
    }
    try check(
        rejectedUnsafeTargetDirectory
            && manager.fileExists(atPath: privatePayload.path)
            && !manager.fileExists(
                atPath: unsafeTargetDirectory.appendingPathComponent("private.txt").path
            ),
        "直接合并拒绝不可信的已有目标子目录"
    )

    print("全部 \(passed) 项核心检查通过。")
} catch {
    FileHandle.standardError.write(Data("测试失败：\(error.localizedDescription)\n".utf8))
    exit(1)
}
