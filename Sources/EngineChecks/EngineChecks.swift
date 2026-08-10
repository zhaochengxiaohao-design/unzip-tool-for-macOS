import Foundation
import Darwin
import UniversalExtractorCore

@main
struct EngineChecks {
    static func main() async {
        do {
            guard let enginePath = ProcessInfo.processInfo.environment["SEVENZIP_BIN"] else {
                throw CheckError("未设置 SEVENZIP_BIN")
            }
            let engineURL = URL(fileURLWithPath: enginePath)
            let manager = FileManager.default
            let root = manager.temporaryDirectory.appendingPathComponent("万能解压-集成测试-\(UUID().uuidString)", isDirectory: true)
            let source = root.appendingPathComponent("source", isDirectory: true)
            try manager.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("你好，Universal Extractor! 🗜️".utf8).write(to: source.appendingPathComponent("中文 文件.txt"))
            defer { try? manager.removeItem(at: root) }

            let zip = root.appendingPathComponent("sample.zip")
            let sevenZip = root.appendingPathComponent("sample.7z")
            let encrypted = root.appendingPathComponent("secret.7z")
            let tar = root.appendingPathComponent("compound.tar")
            let tarGzip = root.appendingPathComponent("compound.tar.gz")
            let tarBzip = root.appendingPathComponent("compound.tar.bz2")
            let tarXz = root.appendingPathComponent("compound.tar.xz")
            try run(engineURL, ["a", zip.path, source.path])
            try run(engineURL, ["a", sevenZip.path, source.path])
            try run(engineURL, ["a", "-p安全密码", "-mhe=on", encrypted.path, source.path])
            try run(engineURL, ["a", "-ttar", tar.path, source.path])
            try run(engineURL, ["a", "-tgzip", tarGzip.path, tar.path])
            try run(engineURL, ["a", "-tbzip2", tarBzip.path, tar.path])
            try run(engineURL, ["a", "-txz", tarXz.path, tar.path])

            let mystery = root.appendingPathComponent("没有扩展名")
            try manager.copyItem(at: zip, to: mystery)
            let wrongExtension = root.appendingPathComponent("伪装成图片.jpg")
            try manager.copyItem(at: sevenZip, to: wrongExtension)

            let engine = SevenZipEngine(executableURL: engineURL)
            try await verifyLargeTechnicalListing(in: root, fileManager: manager)
            try await verifyLiteralWildcard(
                symbol: "*",
                label: "star",
                engine: engine,
                root: root,
                fileManager: manager
            )
            try await verifyLiteralWildcard(
                symbol: "?",
                label: "question",
                engine: engine,
                root: root,
                fileManager: manager
            )
            try await verifySymbolicLinkCompression(engine: engine, root: root, fileManager: manager)
            try await verifyCompressionCoordinator(
                engineURL: engineURL,
                input: source.appendingPathComponent("中文 文件.txt"),
                root: root,
                fileManager: manager
            )
            try await verifyQuarantinePropagation(
                archive: zip,
                engineURL: engineURL,
                root: root,
                fileManager: manager
            )
            try await verifyUnsafeSharedDestinationRejected(
                archive: zip,
                input: source.appendingPathComponent("中文 文件.txt"),
                engineURL: engineURL,
                root: root,
                fileManager: manager
            )

            let compressionOutputs: [(CompressionFormat, URL)] = [
                (.sevenZip, root.appendingPathComponent("created.7z")),
                (.zip, root.appendingPathComponent("created.zip")),
                (.tar, root.appendingPathComponent("created.tar")),
                (.tarGzip, root.appendingPathComponent("created.tar.gz")),
                (.tarBzip2, root.appendingPathComponent("created.tar.bz2")),
                (.tarXz, root.appendingPathComponent("created.tar.xz"))
            ]
            for (format, output) in compressionOutputs {
                try await engine.compress(CompressionRequest(
                    inputs: [source], outputURL: output, format: format, level: .normal, password: nil
                )) { _ in }
                guard manager.fileExists(atPath: output.path) else { throw CheckError("未创建 \(format.label)") }
                let inspection = try await engine.inspect(output, password: nil)
                guard !inspection.format.isEmpty || !inspection.entries.isEmpty else { throw CheckError("创建的 \(format.label) 无法识别") }
                try await engine.test(output, password: nil) { _ in }
                print("✓ 创建并校验：\(format.label)")
            }

            let sourceFile = source.appendingPathComponent("中文 文件.txt")
            for format in [CompressionFormat.gzip, .bzip2, .xz] {
                let output = root.appendingPathComponent("single.\(format.fileExtension)")
                try await engine.compress(CompressionRequest(
                    inputs: [sourceFile], outputURL: output, format: format, level: .normal, password: nil
                )) { _ in }
                let outputDirectory = root.appendingPathComponent("single-output-\(format.rawValue)", isDirectory: true)
                try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
                try await engine.extract(output, to: outputDirectory, password: nil) { _ in }
                let files = try manager.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
                guard files.count == 1,
                      try String(contentsOf: files[0], encoding: .utf8) == "你好，Universal Extractor! 🗜️" else {
                    throw CheckError("单文件 \(format.label) 往返失败")
                }
                print("✓ 单文件压缩往返：\(format.label)")
            }

            for format in [CompressionFormat.sevenZip, .zip] {
                let output = root.appendingPathComponent("protected.\(format.fileExtension)")
                let creationPassword = format == .sevenZip ? "压缩密码" : "zip-password-123"
                try await engine.compress(CompressionRequest(
                    inputs: [source], outputURL: output, format: format, level: .normal, password: creationPassword
                )) { _ in }
                do {
                    try await engine.test(output, password: nil) { _ in }
                    throw CheckError("创建的加密 \(format.label) 未要求密码")
                } catch ArchiveEngineError.passwordRequired {
                    // Expected.
                }
                try await engine.test(output, password: creationPassword) { _ in }
                print("✓ 密码压缩并校验：\(format.label)")
            }

            let unsafePasswords = [
                "\nsecret",
                "secret\nignored",
                "nul\0ignored",
                String(repeating: "a", count: 257),
            ]
            for (index, unsafePassword) in unsafePasswords.enumerated() {
                let output = root.appendingPathComponent("rejected-password-\(index).7z")
                do {
                    try await engine.compress(CompressionRequest(
                        inputs: [source],
                        outputURL: output,
                        format: .sevenZip,
                        level: .normal,
                        password: unsafePassword
                    )) { _ in }
                    throw CheckError("包含控制字符的密码未被拒绝")
                } catch CompressionError.invalidPassword {
                    guard !manager.fileExists(atPath: output.path) else {
                        throw CheckError("拒绝危险密码后仍生成了压缩包")
                    }
                }
            }
            print("✓ 换行、NUL 与超长密码在进入 7-Zip 前被拒绝")

            for (_, compound) in compressionOutputs.filter({ [.tarGzip, .tarBzip2, .tarXz].contains($0.0) }) {
                let compoundDestination = root.appendingPathComponent("created-compound-\(UUID().uuidString)", isDirectory: true)
                try manager.createDirectory(at: compoundDestination, withIntermediateDirectories: true)
                let coordinator = await MainActor.run { ExtractionCoordinator(engine: SevenZipEngine(executableURL: engineURL)) }
                await MainActor.run {
                    coordinator.setDestination(compoundDestination)
                    coordinator.addFiles([compound], outputMode: .separateFolder)
                }
                let completedJob = try await waitForCompletion(coordinator)
                guard completedJob.state == .completed,
                      let outputURL = completedJob.outputURL,
                      manager.fileExists(atPath: outputURL.appendingPathComponent("source/中文 文件.txt").path) else {
                    throw CheckError("创建的组合格式未完全展开：\(compound.lastPathComponent) — \(completedJob.detail)")
                }
                print("✓ 创建的组合格式完全展开：\(compound.lastPathComponent)")
            }

            for archive in [zip, sevenZip, mystery, wrongExtension] {
                let inspection = try await engine.inspect(archive, password: nil)
                guard !inspection.entries.isEmpty else { throw CheckError("未识别 \(archive.lastPathComponent)") }
                try ArchiveSecurity.validateInspection(inspection)
                try await engine.test(archive, password: nil) { _ in }
                let output = root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
                try manager.createDirectory(at: output, withIntermediateDirectories: true)
                try await engine.extract(archive, to: output, password: nil) { _ in }
                try ArchiveSecurity.validateExtractedTree(at: output)
                print("✓ 内容识别并解压：\(archive.lastPathComponent) [\(inspection.format)]")
            }

            do {
                _ = try await engine.inspect(encrypted, password: nil)
                throw CheckError("加密包未要求密码")
            } catch ArchiveEngineError.passwordRequired {
                print("✓ 加密包密码请求")
            }
            let encryptedInspection = try await engine.inspect(encrypted, password: "安全密码")
            guard !encryptedInspection.entries.isEmpty else { throw CheckError("加密包无法列出") }
            try await engine.test(encrypted, password: "安全密码") { _ in }
            let encryptedOutput = root.appendingPathComponent("encrypted-output", isDirectory: true)
            try manager.createDirectory(at: encryptedOutput, withIntermediateDirectories: true)
            try await engine.extract(encrypted, to: encryptedOutput, password: "安全密码") { _ in }
            print("✓ 加密 7Z 解压")

            for compound in [tarGzip, tarBzip, tarXz] {
                let compoundDestination = root.appendingPathComponent("compound-destination-\(UUID().uuidString)", isDirectory: true)
                try manager.createDirectory(at: compoundDestination, withIntermediateDirectories: true)
                let coordinator = await MainActor.run { ExtractionCoordinator(engine: SevenZipEngine(executableURL: engineURL)) }
                await MainActor.run {
                    coordinator.setDestination(compoundDestination)
                    coordinator.addFiles([compound], outputMode: .separateFolder)
                }
                let completedJob = try await waitForCompletion(coordinator)
                guard completedJob.state == .completed,
                      let outputURL = completedJob.outputURL,
                      manager.fileExists(atPath: outputURL.appendingPathComponent("source/中文 文件.txt").path) else {
                    throw CheckError("组合格式未完全展开：\(compound.lastPathComponent) — \(completedJob.detail)")
                }
                print("✓ 组合格式完全展开：\(compound.lastPathComponent)")
            }

            let queueDestination = root.appendingPathComponent("queue-destination", isDirectory: true)
            try manager.createDirectory(at: queueDestination, withIntermediateDirectories: true)
            let queueCoordinator = await MainActor.run { ExtractionCoordinator(engine: SevenZipEngine(executableURL: engineURL)) }
            await MainActor.run {
                queueCoordinator.setDestination(queueDestination)
                queueCoordinator.addFiles([zip, sevenZip], outputMode: .separateFolder)
            }
            let queuedJobs = try await waitForAllJobs(queueCoordinator, expectedCount: 2)
            guard queuedJobs.allSatisfy({ $0.state == .completed }) else {
                throw CheckError("多任务队列未全部完成")
            }
            try await waitForQueueIdleNotification(queueCoordinator)
            print("✓ 多文件顺序任务队列")

            let splitSource = source.appendingPathComponent("分卷数据.bin")
            try Data(repeating: 0x5A, count: 16_384).write(to: splitSource)
            let splitBase = root.appendingPathComponent("split.7z")
            try run(engineURL, ["a", "-v1k", splitBase.path, splitSource.path])
            let secondVolume = root.appendingPathComponent("split.7z.002")
            let firstVolume = try ArchiveUtilities.normalizedFirstVolume(for: secondVolume)
            guard firstVolume.lastPathComponent == "split.7z.001" else {
                throw CheckError("未从后续分卷定位到首卷")
            }
            let splitInspection = try await engine.inspect(firstVolume, password: nil)
            guard !splitInspection.entries.isEmpty else { throw CheckError("无法读取分卷压缩包") }
            try await engine.test(firstVolume, password: nil) { _ in }
            print("✓ 分卷首卷自动定位并校验")

            let finderSourceDirectory = root.appendingPathComponent("Finder右键测试", isDirectory: true)
            try manager.createDirectory(at: finderSourceDirectory, withIntermediateDirectories: true)
            let finderArchive = finderSourceDirectory.appendingPathComponent("右键解压.zip")
            try run(engineURL, ["a", finderArchive.path, source.path])
            let finderCoordinator = await MainActor.run { ExtractionCoordinator(engine: SevenZipEngine(executableURL: engineURL)) }
            _ = await MainActor.run { finderCoordinator.addExternalFiles([finderArchive]) }
            let finderJob = try await waitForCompletion(finderCoordinator)
            let expectedFinderOutput = finderSourceDirectory.appendingPathComponent("右键解压/source/中文 文件.txt")
            guard finderJob.state == .completed,
                  finderJob.destinationURL == finderSourceDirectory,
                  manager.fileExists(atPath: expectedFinderOutput.path) else {
                throw CheckError("Finder 入口未解压到压缩包所在目录：\(finderJob.detail)")
            }
            print("✓ Finder 右键入口自动输出到压缩包旁边")

            let directDirectory = root.appendingPathComponent("界面直接模式", isDirectory: true)
            try manager.createDirectory(at: directDirectory, withIntermediateDirectories: true)
            let directArchive = directDirectory.appendingPathComponent("直接模式.zip")
            try run(engineURL, ["a", directArchive.path, source.path])
            let directCoordinator = await MainActor.run { ExtractionCoordinator(engine: SevenZipEngine(executableURL: engineURL)) }
            await MainActor.run { directCoordinator.addFiles([directArchive], outputMode: .directlyIntoDestination) }
            let directJob = try await waitForCompletion(directCoordinator)
            guard directJob.state == .completed,
                  directJob.destinationURL == directDirectory,
                  manager.fileExists(atPath: directDirectory.appendingPathComponent("source/中文 文件.txt").path) else {
                throw CheckError("界面直接模式仍依赖输出路径：\(directJob.detail)")
            }
            print("✓ 界面直接模式无需选择路径并输出到压缩包所在目录")

            print("全部实际引擎检查通过。")
        } catch {
            FileHandle.standardError.write(Data("集成测试失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func verifyLargeTechnicalListing(in root: URL, fileManager: FileManager) async throws {
        let fixture = root.appendingPathComponent("large-listing-fixture", isDirectory: true)
        try fileManager.createDirectory(at: fixture, withIntermediateDirectories: false)
        let listingURL = fixture.appendingPathComponent("large-listing.txt")
        let executableURL = fixture.appendingPathComponent("fake-7zz")
        let archiveURL = fixture.appendingPathComponent("ignored.zip")

        let safeEntryCount = 20_000
        let padding = String(repeating: "x", count: 96)
        var listing = """
        Path = ignored.zip
        Type = zip
        Physical Size = 1

        ----------
        """
        listing += "\n"
        listing.reserveCapacity(3_000_000)
        for index in 0..<safeEntryCount {
            listing += "Path = safe/\(index)-\(padding).txt\nSize = 1\nAttributes = A\n\n"
        }
        listing += "Path = ../last-escape.txt\nSize = 1\nAttributes = A\n\n"
        let listingData = Data(listing.utf8)
        guard listingData.count > 2_000_000 else {
            throw CheckError("超大技术列表样本未超过 2 MB")
        }
        try listingData.write(to: listingURL, options: .atomic)
        try Data("""
        #!/bin/sh
        exec /bin/cat "$(/usr/bin/dirname "$0")/large-listing.txt"
        """.utf8).write(to: executableURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executableURL.path
        )
        try Data().write(to: archiveURL)

        let inspection = try await SevenZipEngine(executableURL: executableURL).inspect(archiveURL, password: nil)
        let expectedCount = safeEntryCount + 1
        let firstPath = inspection.entries.first?.path ?? "nil"
        let lastPath = inspection.entries.last?.path ?? "nil"
        guard inspection.entryCount == expectedCount,
              inspection.entries.count == expectedCount,
              inspection.entries.first?.path.hasPrefix("safe/0-") == true,
              inspection.entries.last?.path == "../last-escape.txt" else {
            throw CheckError(
                "超过 2 MB 的技术列表未被完整流式解析"
                    + " (entryCount=\(inspection.entryCount), entries=\(inspection.entries.count), "
                    + "first=\(firstPath), last=\(lastPath), "
                    + "ambiguous=\(inspection.listingIsAmbiguous))"
            )
        }
        do {
            try ArchiveSecurity.validateInspection(inspection)
            throw CheckError("超大技术列表尾部的危险路径未被拦截")
        } catch let error as ArchiveSecurityError {
            guard error == .unsafePath("../last-escape.txt") else { throw error }
        }
        print("✓ 超过 2 MB 的技术列表完整计数并检查尾部危险路径")
    }

    private static func verifyCompressionCoordinator(
        engineURL: URL,
        input: URL,
        root: URL,
        fileManager: FileManager
    ) async throws {
        let fixture = root.appendingPathComponent("compression-coordinator", isDirectory: true)
        let destination = fixture.appendingPathComponent("destination", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let desired = destination.appendingPathComponent("coordinator.7z")
        let expectedPublished = destination.appendingPathComponent("coordinator 2.7z")
        let existingMarker = Data("existing-archive-must-survive".utf8)
        try existingMarker.write(to: desired)

        let recordingEngine = RecordingCompressionEngine(
            delegate: SevenZipEngine(executableURL: engineURL),
            expectedPublishedURL: expectedPublished
        )
        let coordinator = await MainActor.run {
            CompressionCoordinator(engine: recordingEngine, fileManager: FileManager())
        }
        await MainActor.run {
            coordinator.setDestination(destination)
            coordinator.setFormat(.sevenZip)
            coordinator.setLevel(.store)
            coordinator.addInputs([input])
            coordinator.archiveName = "coordinator"
            coordinator.start()
        }
        let result = try await waitForCompressionCompletion(coordinator)
        guard result.state == .completed,
              result.outputURL?.lastPathComponent == expectedPublished.lastPathComponent,
              fileManager.fileExists(atPath: expectedPublished.path) else {
            throw CheckError("压缩协调器未成功排他发布：\(result.detail)")
        }

        var hiddenWorkspaces: [URL] = []
        for _ in 0..<100 {
            hiddenWorkspaces = try fileManager.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix(".万能解压-压缩-") }
            if hiddenWorkspaces.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let record = recordingEngine.record()
        guard try Data(contentsOf: desired) == existingMarker else {
            throw CheckError("压缩协调器覆盖了已有同名归档")
        }
        guard record.compressedOutputURL == record.verifiedOutputURL,
              let stagedArchive = record.compressedOutputURL,
              sameFileSystemObject(
                  stagedArchive.deletingLastPathComponent().deletingLastPathComponent(),
                  destination
              ),
              stagedArchive.deletingLastPathComponent().lastPathComponent.hasPrefix(".万能解压-压缩-"),
              let stagingMode = record.stagingDirectoryMode,
              stagingMode & 0o077 == 0 else {
            throw CheckError("压缩未始终使用目标卷上的私有暂存目录")
        }
        guard !record.publishedCandidateExistedDuringVerification else {
            throw CheckError("压缩包在完整校验前已暴露到最终路径")
        }
        guard hiddenWorkspaces.isEmpty else {
            throw CheckError("压缩成功后遗留私有暂存目录")
        }

        let verifier = SevenZipEngine(executableURL: engineURL)
        let inspection = try await verifier.inspect(expectedPublished, password: nil)
        guard !inspection.entries.isEmpty else { throw CheckError("协调器发布的压缩包无法识别") }
        try await verifier.test(expectedPublished, password: nil) { _ in }
        print("✓ 压缩协调器私有暂存、校验后排他发布且不覆盖同名归档")
    }

    private static func verifyQuarantinePropagation(
        archive: URL,
        engineURL: URL,
        root: URL,
        fileManager: FileManager
    ) async throws {
        let fixture = root.appendingPathComponent("quarantine-propagation", isDirectory: true)
        let destination = fixture.appendingPathComponent("destination", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let quarantinedArchive = fixture.appendingPathComponent("quarantined.zip")
        try fileManager.copyItem(at: archive, to: quarantinedArchive)

        let quarantineValue = Data("0081;65F00000;UniversalExtractor;regression-test".utf8)
        let setResult = quarantineValue.withUnsafeBytes { bytes in
            quarantinedArchive.path.withCString { path in
                "com.apple.quarantine".withCString { name in
                    Darwin.setxattr(path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
        if setResult != 0, errno == ENOTSUP || errno == EPERM {
            print("↷ 当前文件系统不允许设置 quarantine，跳过传播检查")
            return
        }
        guard setResult == 0 else {
            throw CheckError("无法创建 quarantine 测试样本：\(String(cString: strerror(errno)))")
        }

        let coordinator = await MainActor.run {
            ExtractionCoordinator(engine: SevenZipEngine(executableURL: engineURL), fileManager: FileManager())
        }
        await MainActor.run {
            coordinator.setDestination(destination)
            coordinator.addFiles([quarantinedArchive], outputMode: .separateFolder)
        }
        let job = try await waitForCompletion(coordinator)
        guard job.state == .completed, let output = job.outputURL else {
            throw CheckError("quarantine 样本解压失败：\(job.detail)")
        }
        let finalFile = output.appendingPathComponent("source/中文 文件.txt")
        let propagated = try extendedAttribute(named: "com.apple.quarantine", at: finalFile)
        guard propagated == quarantineValue else {
            throw CheckError("quarantine 未原样传播到最终解压文件")
        }
        print("✓ 压缩包 quarantine 原样传播到最终解压文件")
    }

    private static func sameFileSystemObject(_ lhs: URL, _ rhs: URL) -> Bool {
        func canonicalPath(_ url: URL) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let result = url.path.withCString { path in
                buffer.withUnsafeMutableBufferPointer { pointer in
                    Darwin.realpath(path, pointer.baseAddress)
                }
            }
            return result == nil ? nil : String(cString: buffer)
        }
        guard let left = canonicalPath(lhs), let right = canonicalPath(rhs) else { return false }
        return left == right
    }

    private static func verifyUnsafeSharedDestinationRejected(
        archive: URL,
        input: URL,
        engineURL: URL,
        root: URL,
        fileManager: FileManager
    ) async throws {
        let unsafeDestination = root.appendingPathComponent("unsafe-shared-destination", isDirectory: true)
        try fileManager.createDirectory(at: unsafeDestination, withIntermediateDirectories: false)
        guard Darwin.chmod(unsafeDestination.path, 0o777) == 0 else {
            throw CheckError("无法创建非 sticky 共享目录测试样本")
        }

        let compression = await MainActor.run {
            CompressionCoordinator(
                engine: SevenZipEngine(executableURL: engineURL),
                fileManager: FileManager()
            )
        }
        await MainActor.run {
            compression.setDestination(unsafeDestination)
            compression.setFormat(.sevenZip)
            compression.addInputs([input])
            compression.archiveName = "must-not-leak"
            compression.start()
        }
        let compressionResult = try await waitForCompressionCompletion(compression)
        guard compressionResult.state == .failed, compressionResult.outputURL == nil else {
            throw CheckError("压缩未拒绝可被其他用户替换的工作目录路径")
        }

        let extraction = await MainActor.run {
            ExtractionCoordinator(
                engine: SevenZipEngine(executableURL: engineURL),
                fileManager: FileManager()
            )
        }
        await MainActor.run {
            extraction.setDestination(unsafeDestination)
            extraction.addFiles([archive], outputMode: .separateFolder)
        }
        let extractionJob = try await waitForCompletion(extraction)
        guard extractionJob.state == .failed, extractionJob.outputURL == nil else {
            throw CheckError("解压未拒绝可被其他用户替换的工作目录路径")
        }

        let leakedArtifacts = try fileManager.contentsOfDirectory(
            at: unsafeDestination,
            includingPropertiesForKeys: nil
        )
        guard leakedArtifacts.isEmpty else {
            throw CheckError("拒绝不可信目录后仍遗留明文工作文件")
        }
        print("✓ 压缩与解压均拒绝不可信的非 sticky 共享目录路径")
    }

    private static func extendedAttribute(named attributeName: String, at url: URL) throws -> Data {
        let size = url.path.withCString { path in
            attributeName.withCString { name in
                Darwin.getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }
        guard size >= 0 else {
            throw CheckError("读取最终文件 quarantine 失败：\(String(cString: strerror(errno)))")
        }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in
            url.path.withCString { path in
                attributeName.withCString { name in
                    Darwin.getxattr(path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
        guard read == size else { throw CheckError("最终文件 quarantine 长度发生变化") }
        return data
    }

    private static func verifyLiteralWildcard(
        symbol: String,
        label: String,
        engine: SevenZipEngine,
        root: URL,
        fileManager: FileManager
    ) async throws {
        let fixture = root.appendingPathComponent("literal-wildcard-\(label)", isDirectory: true)
        try fileManager.createDirectory(at: fixture, withIntermediateDirectories: false)
        let literalInput = fixture.appendingPathComponent("selected\(symbol).txt")
        let decoySuffix = symbol == "*" ? "private" : "A"
        let decoyInput = fixture.appendingPathComponent("selected\(decoySuffix).txt")
        let literalPayload = Data("literal-\(label)-payload".utf8)
        try literalPayload.write(to: literalInput)
        try Data("must-not-be-selected-\(label)".utf8).write(to: decoyInput)

        let literalArchive = fixture.appendingPathComponent("archive\(symbol).7z")
        let decoyArchiveSuffix = symbol == "*" ? "private" : "A"
        let decoyArchive = fixture.appendingPathComponent("archive\(decoyArchiveSuffix).7z")
        try await engine.compress(CompressionRequest(
            inputs: [literalInput],
            outputURL: literalArchive,
            format: .sevenZip,
            level: .store,
            password: nil
        )) { _ in }
        try await engine.compress(CompressionRequest(
            inputs: [decoyInput],
            outputURL: decoyArchive,
            format: .sevenZip,
            level: .store,
            password: nil
        )) { _ in }

        let inspection = try await engine.inspect(literalArchive, password: nil)
        let archivedNames = Set(inspection.entries.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        guard archivedNames == [literalInput.lastPathComponent] else {
            throw CheckError("字面 \(symbol) 输入被 7-Zip 当作通配符：\(archivedNames.sorted())")
        }
        try await engine.test(literalArchive, password: nil) { _ in }
        let output = fixture.appendingPathComponent("output", isDirectory: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: false)
        try await engine.extract(literalArchive, to: output, password: nil) { _ in }
        let extractedLiteral = output.appendingPathComponent(literalInput.lastPathComponent)
        let extractedDecoy = output.appendingPathComponent(decoyInput.lastPathComponent)
        guard try Data(contentsOf: extractedLiteral) == literalPayload,
              !fileManager.fileExists(atPath: extractedDecoy.path) else {
            throw CheckError("字面 \(symbol) 归档路径在测试或解压时发生扩展")
        }
        print("✓ 字面 \(symbol) 文件名在压缩、识别、测试和解压中均不扩展")
    }

    private static func verifySymbolicLinkCompression(
        engine: SevenZipEngine,
        root: URL,
        fileManager: FileManager
    ) async throws {
        let fixture = root.appendingPathComponent("symbolic-link-compression", isDirectory: true)
        let input = fixture.appendingPathComponent("input", isDirectory: true)
        try fileManager.createDirectory(at: input, withIntermediateDirectories: true)
        let publicPayload = Data("public-content".utf8)
        try publicPayload.write(to: input.appendingPathComponent("public.txt"))

        let secretMarker = Data(("TOP-SECRET-NOT-FOR-ARCHIVE-" + String(repeating: "9f31", count: 1_024)).utf8)
        let externalSecret = fixture.appendingPathComponent("external-secret.txt")
        try secretMarker.write(to: externalSecret)
        let link = input.appendingPathComponent("external-link")
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: externalSecret.path)

        let archive = fixture.appendingPathComponent("links.7z")
        let summary = try CompressionInputSecurity.validate(inputs: [input], outputURL: archive)
        guard summary.containsSymbolicLinks,
              summary.totalLogicalSize == Int64(publicPayload.count) else {
            throw CheckError("压缩输入扫描跟随了符号链接或错误计算了链接目标大小")
        }
        try await engine.compress(CompressionRequest(
            inputs: [input],
            outputURL: archive,
            format: .sevenZip,
            level: .store,
            password: nil
        )) { _ in }
        try await engine.test(archive, password: nil) { _ in }

        let inspection = try await engine.inspect(archive, password: nil)
        guard inspection.entries.contains(where: {
            $0.path.hasSuffix("/external-link") && ($0.attributes?.contains("l") == true || $0.mode?.first == "l")
        }), !inspection.entries.contains(where: { $0.path.hasSuffix("external-secret.txt") }) else {
            throw CheckError("符号链接未按链接条目保存，或外部目标被加入归档")
        }
        let archiveData = try Data(contentsOf: archive)
        guard archiveData.range(of: secretMarker) == nil else {
            throw CheckError("压缩符号链接时泄露了外部目标内容")
        }
        print("✓ 压缩符号链接仅保存链接，不泄露外部目标内容")
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CheckError("创建测试压缩包失败，退出码 \(process.terminationStatus)")
        }
    }

    private static func waitForCompletion(_ coordinator: ExtractionCoordinator) async throws -> ArchiveJob {
        for _ in 0..<600 {
            if let job = await MainActor.run(body: { coordinator.jobs.first }), job.state.isTerminal {
                return job
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CheckError("等待任务完成超时")
    }

    private static func waitForAllJobs(_ coordinator: ExtractionCoordinator, expectedCount: Int) async throws -> [ArchiveJob] {
        for _ in 0..<600 {
            let jobs = await MainActor.run { coordinator.jobs }
            if jobs.count == expectedCount, jobs.allSatisfy({ $0.state.isTerminal }) { return jobs }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CheckError("等待队列完成超时")
    }

    private static func waitForQueueIdleNotification(_ coordinator: ExtractionCoordinator) async throws {
        for _ in 0..<100 {
            if await MainActor.run(body: { coordinator.queueCompletionGeneration > 0 }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CheckError("队列完成后未发布空闲通知")
    }

    private static func waitForCompressionCompletion(
        _ coordinator: CompressionCoordinator
    ) async throws -> (state: CompressionState, outputURL: URL?, detail: String) {
        for _ in 0..<600 {
            let snapshot = await MainActor.run {
                (coordinator.state, coordinator.outputURL, coordinator.detail)
            }
            if snapshot.0 == .completed || snapshot.0 == .failed || snapshot.0 == .cancelled {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CheckError("等待压缩任务完成超时")
    }

    private final class RecordingCompressionEngine: ArchiveCompressionEngine, @unchecked Sendable {
        struct Record {
            let compressedOutputURL: URL?
            let verifiedOutputURL: URL?
            let stagingDirectoryMode: mode_t?
            let publishedCandidateExistedDuringVerification: Bool
        }

        private let delegate: SevenZipEngine
        private let expectedPublishedURL: URL
        private let lock = NSLock()
        private var compressedOutputURL: URL?
        private var verifiedOutputURL: URL?
        private var stagingDirectoryMode: mode_t?
        private var publishedCandidateExistedDuringVerification = false

        init(delegate: SevenZipEngine, expectedPublishedURL: URL) {
            self.delegate = delegate
            self.expectedPublishedURL = expectedPublishedURL
        }

        func compress(
            _ request: CompressionRequest,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            var status = stat()
            let parent = request.outputURL.deletingLastPathComponent()
            let result = parent.path.withCString { Darwin.lstat($0, &status) }
            recordCompression(
                outputURL: request.outputURL,
                stagingMode: result == 0 ? status.st_mode & 0o7777 : nil
            )
            try await delegate.compress(request, progress: progress)
        }

        func verify(
            _ request: CompressionRequest,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            let candidateExists = FileManager.default.fileExists(atPath: expectedPublishedURL.path)
            recordVerification(outputURL: request.outputURL, candidateExists: candidateExists)
            try await delegate.verify(request, progress: progress)
        }

        func cancel() {
            delegate.cancel()
        }

        func record() -> Record {
            lock.lock()
            defer { lock.unlock() }
            return Record(
                compressedOutputURL: compressedOutputURL,
                verifiedOutputURL: verifiedOutputURL,
                stagingDirectoryMode: stagingDirectoryMode,
                publishedCandidateExistedDuringVerification: publishedCandidateExistedDuringVerification
            )
        }

        private func recordCompression(outputURL: URL, stagingMode: mode_t?) {
            lock.lock()
            compressedOutputURL = outputURL
            stagingDirectoryMode = stagingMode
            lock.unlock()
        }

        private func recordVerification(outputURL: URL, candidateExists: Bool) {
            lock.lock()
            verifiedOutputURL = outputURL
            publishedCandidateExistedDuringVerification = candidateExists
            lock.unlock()
        }
    }

    private struct CheckError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
