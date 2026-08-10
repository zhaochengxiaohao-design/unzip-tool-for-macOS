import Foundation

public final class SevenZipEngine: ArchiveEngine, @unchecked Sendable {
    private let executableURL: URL?
    private let processLock = NSLock()
    private var activeProcess: Process?
    private var cancelled = false

    public init(executableURL: URL? = nil) {
        if let executableURL {
            self.executableURL = executableURL
        } else if let environmentPath = ProcessInfo.processInfo.environment["SEVENZIP_BIN"] {
            self.executableURL = URL(fileURLWithPath: environmentPath)
        } else if let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil) {
            self.executableURL = bundled
        } else {
            self.executableURL = nil
        }
    }

    public func inspect(_ archive: URL, password: String?) async throws -> ArchiveInspection {
        let result = try await run(
            arguments: ["l", "-slt", "-bd", archive.path],
            password: password,
            progress: nil
        )
        try classifyFailure(result, archive: archive, suppliedPassword: password != nil)
        let inspection = Self.parseTechnicalListing(result.output)
        guard !inspection.format.isEmpty || !inspection.entries.isEmpty else {
            throw ArchiveEngineError.unsupported
        }
        return inspection
    }

    public func test(_ archive: URL, password: String?, progress: @escaping @Sendable (Double) -> Void) async throws {
        let result = try await run(
            arguments: ["t", "-y", "-bso1", "-bse1", "-bsp1", archive.path],
            password: password,
            progress: progress
        )
        try classifyFailure(result, archive: archive, suppliedPassword: password != nil)
    }

    public func extract(_ archive: URL, to destination: URL, password: String?, progress: @escaping @Sendable (Double) -> Void) async throws {
        let result = try await run(
            arguments: ["x", "-y", "-aoa", "-bso1", "-bse1", "-bsp1", "-o\(destination.path)", archive.path],
            password: password,
            progress: progress
        )
        try classifyFailure(result, archive: archive, suppliedPassword: password != nil)
    }

    public func cancel() {
        processLock.lock()
        cancelled = true
        let process = activeProcess
        processLock.unlock()
        if let process, process.isRunning {
            process.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    public static func parseTechnicalListing(_ text: String) -> ArchiveInspection {
        var format = ""
        var physicalSize: Int64?
        var entries: [ArchiveEntry] = []
        var encrypted = false
        var current: [String: String] = [:]
        var inEntries = false

        func flushEntry() {
            guard inEntries, let path = current["Path"], !path.isEmpty else {
                current.removeAll(keepingCapacity: true)
                return
            }
            let entryEncrypted = current["Encrypted"] == "+"
            encrypted = encrypted || entryEncrypted
            entries.append(ArchiveEntry(
                path: path,
                size: current["Size"].flatMap(Int64.init),
                attributes: current["Attributes"],
                symbolicLinkTarget: current["Symbolic Link"] ?? current["SymLink"]
            ))
            current.removeAll(keepingCapacity: true)
        }

        for rawLine in text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("----------") {
                flushEntry()
                inEntries = true
                continue
            }
            if line.isEmpty {
                flushEntry()
                continue
            }
            guard let separator = line.range(of: " = ") else { continue }
            let key = String(line[..<separator.lowerBound])
            let value = String(line[separator.upperBound...])
            if !inEntries {
                if key == "Type" { format = value }
                if key == "Physical Size" { physicalSize = Int64(value) }
                if key == "Encrypted", value == "+" { encrypted = true }
            } else {
                current[key] = value
            }
        }
        flushEntry()

        let total = entries.compactMap(\.size).reduce(Int64(0), &+)
        return ArchiveInspection(
            format: format,
            physicalSize: physicalSize,
            totalUncompressedSize: total,
            encrypted: encrypted,
            entries: entries
        )
    }

    private struct ProcessResult: Sendable {
        var status: Int32
        var output: String
        var wasCancelled: Bool
    }

    private func run(
        arguments: [String],
        password: String?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> ProcessResult {
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ArchiveEngineError.engineUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let inputPipe = Pipe()
            let collector = OutputCollector(progress: progress)
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            process.standardInput = password == nil ? FileHandle.nullDevice : inputPipe

            processLock.lock()
            cancelled = false
            activeProcess = process
            processLock.unlock()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collector.append(data) }
            }

            process.terminationHandler = { [weak self] completed in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                let remainder = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainder.isEmpty { collector.append(remainder) }
                self?.processLock.lock()
                let wasCancelled = self?.cancelled ?? false
                self?.activeProcess = nil
                self?.processLock.unlock()
                continuation.resume(returning: ProcessResult(
                    status: completed.terminationStatus,
                    output: collector.text,
                    wasCancelled: wasCancelled
                ))
            }

            do {
                try process.run()
                if let password {
                    inputPipe.fileHandleForWriting.write(Data((password + "\n").utf8))
                    try? inputPipe.fileHandleForWriting.close()
                }
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                processLock.lock()
                activeProcess = nil
                processLock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    private func classifyFailure(_ result: ProcessResult, archive: URL, suppliedPassword: Bool) throws {
        if result.wasCancelled { throw ArchiveEngineError.cancelled }
        guard result.status != 0 else { return }
        let lower = result.output.lowercased()

        if lower.contains("wrong password") || lower.contains("data error in encrypted file") {
            throw suppliedPassword ? ArchiveEngineError.wrongPassword : ArchiveEngineError.passwordRequired
        }
        if lower.contains("enter password") || lower.contains("password is not defined") || lower.contains("encrypted archive") {
            throw suppliedPassword ? ArchiveEngineError.wrongPassword : ArchiveEngineError.passwordRequired
        }
        if lower.contains("missing volume") || lower.contains("unexpected end of archive") || lower.contains("can't open as archive volume") {
            throw ArchiveEngineError.missingVolume(briefMessage(from: result.output))
        }
        if lower.contains("crc failed") || lower.contains("data error") || lower.contains("headers error") || lower.contains("unexpected end of data") {
            throw ArchiveEngineError.corrupt(briefMessage(from: result.output))
        }
        if lower.contains("is not archive") || lower.contains("cannot open the file as archive") || lower.contains("can not open the file as archive") {
            throw ArchiveEngineError.unsupported
        }
        throw ArchiveEngineError.processFailed(briefMessage(
            from: result.output,
            fallback: AppLocalization.format("退出码 %d，文件：%@", result.status, archive.lastPathComponent)
        ))
    }

    private func briefMessage(from output: String, fallback: String = AppLocalization.text("未知错误")) -> String {
        let useful = output
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("7-Zip") && !$0.hasPrefix("Scanning") }
        return useful.suffix(3).joined(separator: "；").prefix(300).description.isEmpty ? fallback : String(useful.suffix(3).joined(separator: "；").prefix(300))
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let progress: (@Sendable (Double) -> Void)?

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > 2_000_000 {
            data.removeFirst(data.count - 2_000_000)
        }
        let chunkText = String(decoding: chunk, as: UTF8.self)
        lock.unlock()

        guard let progress,
              let regex = try? NSRegularExpression(pattern: #"(?:^|\s)(\d{1,3})%"#),
              let match = regex.matches(in: chunkText, range: NSRange(chunkText.startIndex..., in: chunkText)).last,
              let range = Range(match.range(at: 1), in: chunkText),
              let value = Double(chunkText[range]) else { return }
        progress(min(max(value / 100, 0), 1))
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
