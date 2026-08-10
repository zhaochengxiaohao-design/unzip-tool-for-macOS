import Foundation
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

    private struct CheckError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
