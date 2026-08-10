import Foundation
import Darwin

public final class SevenZipEngine: ArchiveEngine, ArchiveCompressionEngine, @unchecked Sendable {
    private let executableURL: URL?
    private let processLock = NSLock()
    private var activeOperation: OperationContext?

    private final class OperationContext: @unchecked Sendable {
        var activeProcess: Process?
        var cancelled = false
    }

    public init(executableURL: URL? = nil) {
        if let executableURL {
            self.executableURL = executableURL
        } else if let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil) {
            self.executableURL = bundled
        } else {
            self.executableURL = nil
        }
    }

    public func inspect(_ archive: URL, password: String?) async throws -> ArchiveInspection {
        try validatePassword(password)
        return try await withOperation { operation in
            let result = try await self.run(
                arguments: ["l", "-spd", "-slt", "-bd", archive.path],
                password: password,
                progress: nil,
                operation: operation,
                captureTechnicalListing: true
            )
            guard !result.listingHadInvalidUTF8, let inspection = result.inspection else {
                throw ArchiveEngineError.processFailed(AppLocalization.text("压缩包文件清单不是有效的 UTF-8 文本。"))
            }
            guard !result.listingLineLimitExceeded else {
                throw ArchiveEngineError.processFailed(AppLocalization.text("压缩包文件清单包含过长的元数据行。"))
            }
            guard !result.listingResourceLimitExceeded else {
                throw ArchiveEngineError.processFailed(AppLocalization.text("压缩包文件清单超过安全元数据预算。"))
            }
            if result.listingEntryLimitExceeded {
                return inspection
            }
            try self.classifyFailure(result, archive: archive, suppliedPassword: password != nil)
            guard !inspection.format.isEmpty || inspection.entryCount > 0 else {
                throw ArchiveEngineError.unsupported
            }
            return inspection
        }
    }

    public func test(_ archive: URL, password: String?, progress: @escaping @Sendable (Double) -> Void) async throws {
        try validatePassword(password)
        try await withOperation { operation in
            let result = try await self.run(
                arguments: ["t", "-spd", "-y", "-bso1", "-bse1", "-bsp1", archive.path],
                password: password,
                progress: progress,
                operation: operation
            )
            try self.classifyFailure(result, archive: archive, suppliedPassword: password != nil)
        }
    }

    public func extract(_ archive: URL, to destination: URL, password: String?, progress: @escaping @Sendable (Double) -> Void) async throws {
        try validatePassword(password)
        try await withOperation { operation in
            let result = try await self.run(
                arguments: ["x", "-spd", "-y", "-aoa", "-bso1", "-bse1", "-bsp1", "-o\(destination.path)", archive.path],
                password: password,
                progress: progress,
                operation: operation
            )
            try self.classifyFailure(result, archive: archive, suppliedPassword: password != nil)
        }
    }

    public func compress(_ request: CompressionRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withOperation { operation in
            guard !request.inputs.isEmpty else { throw CompressionError.noInput }
            _ = try CompressionInputSecurity.validate(
                inputs: request.inputs,
                outputURL: request.outputURL,
                shouldCancel: { Task.isCancelled || self.isCancelled(operation) }
            )
            if request.format.requiresSingleRegularFile {
                guard request.inputs.count == 1,
                      self.isRegularFileWithoutFollowingLinks(request.inputs[0]) else {
                    throw CompressionError.singleRegularFileRequired
                }
            }
            if request.password != nil && !request.format.supportsPassword {
                throw CompressionError.passwordUnsupported
            }
            if let password = request.password, !ArchivePasswordPolicy.isValid(password) {
                throw CompressionError.invalidPassword
            }
            if request.format == .zip, let password = request.password, !password.unicodeScalars.allSatisfy(\.isASCII) {
                throw CompressionError.zipPasswordRequiresASCII
            }
            try self.validateOutputIsOutsideInputs(request)

            switch request.format {
            case .tarGzip, .tarBzip2, .tarXz:
                try await self.compressTarWrapper(request, operation: operation, progress: progress)
            default:
                let type: String
                switch request.format {
                case .sevenZip: type = "7z"
                case .zip: type = "zip"
                case .tar: type = "tar"
                case .gzip: type = "gzip"
                case .bzip2: type = "bzip2"
                case .xz: type = "xz"
                default: preconditionFailure("Handled above")
                }
                try await self.createArchive(
                    type: type,
                    inputs: request.inputs,
                    output: request.outputURL,
                    level: request.level,
                    password: request.password,
                    operation: operation,
                    progress: progress
                )
            }
        }
    }

    public func verify(_ request: CompressionRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        if let password = request.password, !ArchivePasswordPolicy.isValid(password) {
            throw CompressionError.invalidPassword
        }
        try await withOperation { operation in
            let result = try await self.run(
                arguments: ["t", "-spd", "-y", "-bso1", "-bse1", "-bsp1", request.outputURL.path],
                password: request.password,
                progress: progress,
                operation: operation
            )
            try self.classifyFailure(result, archive: request.outputURL, suppliedPassword: request.password != nil)
        }
    }

    private func validateOutputIsOutsideInputs(_ request: CompressionRequest) throws {
        let outputParent = request.outputURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        for input in request.inputs {
            var status = stat()
            guard input.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { continue }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { continue }
            let directoryPath = input.resolvingSymlinksInPath().standardizedFileURL.path
            if outputParent == directoryPath || outputParent.hasPrefix(directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/") {
                throw CompressionError.outputInsideInput
            }
        }
    }

    private func isRegularFileWithoutFollowingLinks(_ url: URL) -> Bool {
        var status = stat()
        return url.path.withCString { Darwin.lstat($0, &status) } == 0
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private func validatePassword(_ password: String?) throws {
        if let password, !ArchivePasswordPolicy.isValid(password) {
            throw ArchiveEngineError.invalidPassword
        }
    }

    public func cancel() {
        processLock.lock()
        let operation = activeOperation
        processLock.unlock()
        if let operation { cancel(operation) }
    }

    public static func parseTechnicalListing(_ text: String) -> ArchiveInspection {
        let parser = TechnicalListingParser()
        for rawLine in text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            parser.consume(String(rawLine))
        }
        return parser.finish()
    }

    private struct ProcessResult: Sendable {
        var status: Int32
        var output: String
        var wasCancelled: Bool
        var inspection: ArchiveInspection?
        var listingHadInvalidUTF8: Bool
        var listingEntryLimitExceeded: Bool
        var listingLineLimitExceeded: Bool
        var listingResourceLimitExceeded: Bool
    }

    private func run(
        arguments: [String],
        password: String?,
        passwordResponseCount: Int = 1,
        progress: (@Sendable (Double) -> Void)?,
        operation: OperationContext,
        captureTechnicalListing: Bool = false
    ) async throws -> ProcessResult {
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ArchiveEngineError.engineUnavailable
        }
        guard !isCancelled(operation), !Task.isCancelled else {
            throw ArchiveEngineError.cancelled
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let inputPipe = Pipe()
            let collector = OutputCollector(progress: progress, captureTechnicalListing: captureTechnicalListing)
            let readerFinished = DispatchGroup()
            readerFinished.enter()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            process.standardInput = password == nil ? FileHandle.nullDevice : inputPipe

            processLock.lock()
            let canStart = activeOperation === operation && !operation.cancelled && operation.activeProcess == nil
            if canStart { operation.activeProcess = process }
            processLock.unlock()
            guard canStart else {
                continuation.resume(throwing: ArchiveEngineError.cancelled)
                return
            }

            process.terminationHandler = { [weak self] completed in
                DispatchQueue.global(qos: .utility).async {
                    readerFinished.wait()
                    let collected = collector.finish()
                    self?.clearProcess(completed, from: operation)
                    let wasCancelled = self?.isCancelled(operation) ?? true
                    continuation.resume(returning: ProcessResult(
                        status: completed.terminationStatus,
                        output: collected.output,
                        wasCancelled: wasCancelled,
                        inspection: collected.inspection,
                        listingHadInvalidUTF8: collected.hadInvalidUTF8,
                        listingEntryLimitExceeded: collected.entryLimitExceeded,
                        listingLineLimitExceeded: collected.lineLimitExceeded,
                        listingResourceLimitExceeded: collected.resourceLimitExceeded
                    ))
                }
            }

            do {
                try process.run()
                DispatchQueue.global(qos: .utility).async {
                    defer { readerFinished.leave() }
                    while true {
                        let data = outputPipe.fileHandleForReading.readData(ofLength: 64 * 1_024)
                        guard !data.isEmpty else { return }
                        collector.append(data)
                        if collector.takeListingTerminationRequest() {
                            self.requestTermination(of: process)
                        }
                    }
                }
                if let password {
                    var responseData = Data()
                    for _ in 0..<max(passwordResponseCount, 1) {
                        responseData.append(contentsOf: password.utf8)
                        responseData.append(0x0A)
                    }
                    inputPipe.fileHandleForWriting.write(responseData)
                    responseData.resetBytes(in: responseData.startIndex..<responseData.endIndex)
                    responseData.removeAll(keepingCapacity: false)
                    try? inputPipe.fileHandleForWriting.close()
                }
                if isCancelled(operation) || Task.isCancelled {
                    requestTermination(of: process)
                }
            } catch {
                readerFinished.leave()
                clearProcess(process, from: operation)
                continuation.resume(throwing: isCancelled(operation) ? ArchiveEngineError.cancelled : error)
            }
        }
    }

    private func createArchive(
        type: String,
        inputs: [URL],
        output: URL,
        level: CompressionLevel,
        password: String?,
        operation: OperationContext,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var arguments = ["a", "-spd", "-snl", "-t\(type)", "-y", "-bso1", "-bse1", "-bsp1"]
        if type != "tar" { arguments.append("-mx=\(level.rawValue)") }
        if password != nil {
            arguments.append("-p")
            if type == "7z" { arguments.append("-mhe=on") }
            if type == "zip" { arguments.append("-mem=AES256") }
        }
        arguments.append(output.path)
        arguments.append(contentsOf: inputs.map(\.path))
        let result = try await run(
            arguments: arguments,
            password: password,
            passwordResponseCount: 1,
            progress: progress,
            operation: operation
        )
        try classifyFailure(result, archive: output, suppliedPassword: password != nil)
    }

    private func compressTarWrapper(
        _ request: CompressionRequest,
        operation: OperationContext,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let temporaryDirectory = request.outputURL.deletingLastPathComponent()
            .appendingPathComponent(".UniversalExtractor-Compression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        guard chmod(temporaryDirectory.path, 0o700) == 0 else {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw ArchiveEngineError.processFailed(AppLocalization.text("无法保护临时压缩目录。"))
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let temporaryTar = temporaryDirectory.appendingPathComponent("payload.tar")

        try await createArchive(
            type: "tar",
            inputs: request.inputs,
            output: temporaryTar,
            level: request.level,
            password: nil,
            operation: operation
        ) {
            progress($0 * 0.7)
        }
        if Task.isCancelled || isCancelled(operation) { throw ArchiveEngineError.cancelled }
        let wrapperType: String
        switch request.format {
        case .tarGzip: wrapperType = "gzip"
        case .tarBzip2: wrapperType = "bzip2"
        case .tarXz: wrapperType = "xz"
        default: preconditionFailure("Tar wrapper expected")
        }
        try await createArchive(
            type: wrapperType,
            inputs: [temporaryTar],
            output: request.outputURL,
            level: request.level,
            password: nil,
            operation: operation
        ) {
            progress(0.7 + $0 * 0.3)
        }
    }

    private func withOperation<T: Sendable>(
        _ body: @escaping @Sendable (OperationContext) async throws -> T
    ) async throws -> T {
        guard !Task.isCancelled else { throw ArchiveEngineError.cancelled }
        let operation = try beginOperation()

        return try await withTaskCancellationHandler {
            defer { finish(operation) }
            guard !Task.isCancelled, !isCancelled(operation) else {
                throw ArchiveEngineError.cancelled
            }
            do {
                let value = try await body(operation)
                guard !Task.isCancelled, !isCancelled(operation) else {
                    throw ArchiveEngineError.cancelled
                }
                return value
            } catch is CancellationError {
                throw ArchiveEngineError.cancelled
            }
        } onCancel: { [weak self] in
            self?.cancel(operation)
        }
    }

    private func beginOperation() throws -> OperationContext {
        let operation = OperationContext()
        processLock.lock()
        defer { processLock.unlock() }
        guard activeOperation == nil else {
            throw ArchiveEngineError.processFailed(AppLocalization.text("解压引擎正在处理另一项任务。"))
        }
        activeOperation = operation
        return operation
    }

    private func finish(_ operation: OperationContext) {
        processLock.lock()
        if activeOperation === operation {
            activeOperation = nil
            operation.activeProcess = nil
        }
        processLock.unlock()
    }

    private func cancel(_ operation: OperationContext) {
        processLock.lock()
        guard activeOperation === operation else {
            processLock.unlock()
            return
        }
        operation.cancelled = true
        let process = operation.activeProcess
        processLock.unlock()
        if let process { requestTermination(of: process) }
    }

    private func isCancelled(_ operation: OperationContext) -> Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return operation.cancelled || activeOperation !== operation
    }

    private func clearProcess(_ process: Process, from operation: OperationContext) {
        processLock.lock()
        if activeOperation === operation, operation.activeProcess === process {
            operation.activeProcess = nil
        }
        processLock.unlock()
    }

    private func requestTermination(of process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
    struct Result: Sendable {
        var output: String
        var inspection: ArchiveInspection?
        var hadInvalidUTF8: Bool
        var entryLimitExceeded: Bool
        var lineLimitExceeded: Bool
        var resourceLimitExceeded: Bool
    }

    private static let maximumTailBytes = 2_000_000
    private static let maximumLineBytes = 1_048_576
    private static let progressExpression = try! NSRegularExpression(pattern: #"(?:^|\s)(\d{1,3})%"#)
    private let lock = NSLock()
    private var tailData = Data()
    private var pendingLineData = Data()
    private var hadInvalidUTF8 = false
    private var finished = false
    private var lineLimitExceeded = false
    private var requestedListingTermination = false
    private let progress: (@Sendable (Double) -> Void)?
    private let listingParser: TechnicalListingParser?

    func takeListingTerminationRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard (listingParser?.entryLimitExceeded == true
                || listingParser?.resourceLimitExceeded == true
                || lineLimitExceeded),
              !requestedListingTermination else { return false }
        requestedListingTermination = true
        return true
    }

    init(progress: (@Sendable (Double) -> Void)?, captureTechnicalListing: Bool) {
        self.progress = progress
        listingParser = captureTechnicalListing ? TechnicalListingParser() : nil
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var progressValues: [Double] = []
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        tailData.append(chunk)
        if tailData.count > Self.maximumTailBytes {
            tailData.removeFirst(tailData.count - Self.maximumTailBytes)
        }
        if !lineLimitExceeded {
            pendingLineData.append(chunk)
            progressValues = drainCompleteLines()
            if pendingLineData.count > Self.maximumLineBytes {
                pendingLineData.removeAll(keepingCapacity: false)
                lineLimitExceeded = listingParser != nil
            }
        }
        lock.unlock()

        if let progress {
            for value in progressValues { progress(value) }
        }
    }

    func finish() -> Result {
        lock.lock()
        defer { lock.unlock() }
        if !finished {
            if !pendingLineData.isEmpty { consumeLineData(pendingLineData) }
            pendingLineData.removeAll(keepingCapacity: false)
            finished = true
        }
        return Result(
            output: String(decoding: tailData, as: UTF8.self),
            inspection: listingParser?.finish(),
            hadInvalidUTF8: hadInvalidUTF8,
            entryLimitExceeded: listingParser?.entryLimitExceeded ?? false,
            lineLimitExceeded: lineLimitExceeded,
            resourceLimitExceeded: listingParser?.resourceLimitExceeded ?? false
        )
    }

    /// Must be called with `lock` held. UTF-8 code points are never split because
    /// decoding happens only after an ASCII CR/LF byte boundary is found.
    private func drainCompleteLines() -> [Double] {
        var progressValues: [Double] = []
        while let delimiter = pendingLineData.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = Data(pendingLineData[..<delimiter])
            var consumedThrough = pendingLineData.index(after: delimiter)
            if pendingLineData[delimiter] == 0x0D,
               consumedThrough < pendingLineData.endIndex,
               pendingLineData[consumedThrough] == 0x0A {
                consumedThrough = pendingLineData.index(after: consumedThrough)
            }
            pendingLineData.removeSubrange(..<consumedThrough)
            if let value = consumeLineData(line) { progressValues.append(value) }
        }
        return progressValues
    }

    /// Must be called with `lock` held.
    @discardableResult
    private func consumeLineData(_ data: Data) -> Double? {
        guard let line = String(data: data, encoding: .utf8) else {
            hadInvalidUTF8 = true
            return nil
        }
        listingParser?.consume(line)
        guard progress != nil else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = Self.progressExpression.matches(in: line, range: range).last,
              let valueRange = Range(match.range(at: 1), in: line),
              let value = Double(line[valueRange]) else { return nil }
        return min(max(value / 100, 0), 1)
    }
}

private final class TechnicalListingParser {
    private static let maximumEntryCount = 1_000_000
    private static let maximumMetadataBytes = 128 * 1_024 * 1_024
    private static let maximumFieldBytes = 32_768
    private var format = ""
    private var physicalSize: Int64?
    private var encrypted = false
    private var entries: [ArchiveEntry] = []
    private var entryCount = 0
    private var totalUncompressedSize: Int64 = 0
    private var hasUnknownEntrySizes = false
    private var uncompressedSizeOverflowed = false
    private var listingIsAmbiguous = false
    private var metadataBytes = 0
    private(set) var resourceLimitExceeded = false
    private var current: [String: String] = [:]
    private var inEntries = false
    private var didFinish = false

    var entryLimitExceeded: Bool { entryCount > Self.maximumEntryCount }

    func consume(_ line: String) {
        guard !didFinish else { return }
        if entryLimitExceeded || resourceLimitExceeded { return }
        let lineBytes = line.utf8.count
        let accumulated = metadataBytes.addingReportingOverflow(lineBytes + 1)
        if accumulated.overflow
            || accumulated.partialValue > Self.maximumMetadataBytes
            || lineBytes > Self.maximumFieldBytes {
            listingIsAmbiguous = true
            resourceLimitExceeded = true
            return
        }
        metadataBytes = accumulated.partialValue
        if line.hasPrefix("----------") {
            flushEntry()
            inEntries = true
            return
        }
        if line.isEmpty {
            flushEntry()
            return
        }
        guard let separator = line.range(of: " = ") else {
            if inEntries { listingIsAmbiguous = true }
            return
        }
        let key = String(line[..<separator.lowerBound])
        let value = String(line[separator.upperBound...])
        if inEntries {
            if current[key] != nil { listingIsAmbiguous = true }
            current[key] = value
        } else {
            if key == "Type" { format = value }
            if key == "Physical Size" { physicalSize = Int64(value) }
            if key == "Encrypted", value == "+" { encrypted = true }
        }
    }

    func finish() -> ArchiveInspection {
        if !didFinish {
            flushEntry()
            didFinish = true
        }
        return ArchiveInspection(
            format: format,
            physicalSize: physicalSize,
            totalUncompressedSize: totalUncompressedSize,
            encrypted: encrypted,
            entries: entries,
            entryCount: entryCount,
            hasUnknownEntrySizes: hasUnknownEntrySizes,
            uncompressedSizeOverflowed: uncompressedSizeOverflowed,
            listingIsAmbiguous: listingIsAmbiguous
        )
    }

    private func flushEntry() {
        guard inEntries, let path = current["Path"], !path.isEmpty else {
            current.removeAll(keepingCapacity: true)
            return
        }

        let size: Int64?
        if let rawSize = current["Size"], let parsedSize = Int64(rawSize), parsedSize >= 0 {
            size = parsedSize
            if !uncompressedSizeOverflowed {
                let addition = totalUncompressedSize.addingReportingOverflow(parsedSize)
                if addition.overflow {
                    totalUncompressedSize = Int64.max
                    uncompressedSizeOverflowed = true
                } else {
                    totalUncompressedSize = addition.partialValue
                }
            }
        } else {
            size = nil
            hasUnknownEntrySizes = true
        }

        let count = entryCount.addingReportingOverflow(1)
        entryCount = count.overflow ? Int.max : count.partialValue
        encrypted = encrypted || current["Encrypted"] == "+"
        entries.append(ArchiveEntry(
            path: path,
            size: size,
            attributes: nonempty(current["Attributes"]),
            symbolicLinkTarget: nonempty(current["Symbolic Link"] ?? current["SymLink"]),
            mode: nonempty(current["Mode"]),
            hardLinkTarget: nonempty(current["Hard Link"]),
            deviceMajor: current["Device Major"].flatMap(Int.init),
            deviceMinor: current["Device Minor"].flatMap(Int.init)
        ))
        current.removeAll(keepingCapacity: true)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
