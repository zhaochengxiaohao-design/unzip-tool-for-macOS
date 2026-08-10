import Foundation
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
    try check(parsed.format == "zip" && parsed.totalUncompressedSize == 320 && parsed.entries.count == 2 && parsed.encrypted, "7-Zip 技术列表解析")

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
    let sourceFile = staging.appendingPathComponent("readme.txt")
    let existingFile = destination.appendingPathComponent("readme.txt")
    try Data("new".utf8).write(to: sourceFile)
    try Data("old".utf8).write(to: existingFile)
    defer { try? manager.removeItem(at: root) }
    try check(FileMerger.hasCollisions(from: staging, into: destination), "重名检测")
    try FileMerger.merge(from: staging, into: destination, policy: .keepBoth)
    try check(String(contentsOf: existingFile, encoding: .utf8) == "old", "保留原文件")
    try check(String(contentsOf: destination.appendingPathComponent("readme 2.txt"), encoding: .utf8) == "new", "新文件自动改名")

    print("全部 \(passed) 项核心检查通过。")
} catch {
    FileHandle.standardError.write(Data("测试失败：\(error.localizedDescription)\n".utf8))
    exit(1)
}
