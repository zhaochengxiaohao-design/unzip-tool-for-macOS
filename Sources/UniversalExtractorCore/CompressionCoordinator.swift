import Foundation
import Combine
import Darwin

@MainActor
public final class CompressionCoordinator: ObservableObject {
    @Published public private(set) var inputs: [URL] = []
    @Published public var destinationURL: URL?
    @Published public var archiveName = ""
    @Published public var format: CompressionFormat = .sevenZip
    @Published public var level: CompressionLevel = .normal
    @Published public var password = ""
    @Published public private(set) var state: CompressionState = .idle
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var detail = AppLocalization.text("添加文件或文件夹以开始")
    @Published public private(set) var outputURL: URL?
    @Published public var presentedError: String?

    private let engine: ArchiveCompressionEngine
    private let fileManager: FileManager
    private var worker: Task<Void, Never>?
    private var runtimeSpaceFailure: Int64?
    private var runtimeCapacityFailure = false

    public init(engine: ArchiveCompressionEngine = SevenZipEngine(), fileManager: FileManager = .default) {
        self.engine = engine
        self.fileManager = fileManager
        if let saved = UserDefaults.standard.string(forKey: "lastCompressionDestination"), !saved.isEmpty {
            let url = URL(fileURLWithPath: saved, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                destinationURL = url
            }
        }
        if let raw = UserDefaults.standard.string(forKey: "compressionFormat"), let saved = CompressionFormat(rawValue: raw) {
            format = saved
        }
        if UserDefaults.standard.object(forKey: "compressionLevel") != nil,
           let saved = CompressionLevel(rawValue: UserDefaults.standard.integer(forKey: "compressionLevel")) {
            level = saved
        }
    }

    deinit { worker?.cancel() }

    public var isRunning: Bool { state == .compressing }

    public func setDestination(_ url: URL) {
        destinationURL = url
        UserDefaults.standard.set(url.path, forKey: "lastCompressionDestination")
    }

    public func setFormat(_ value: CompressionFormat) {
        format = value
        UserDefaults.standard.set(value.rawValue, forKey: "compressionFormat")
        if !value.supportsPassword { password = "" }
    }

    public func setLevel(_ value: CompressionLevel) {
        level = value
        UserDefaults.standard.set(value.rawValue, forKey: "compressionLevel")
    }

    public func addInputs(_ urls: [URL]) {
        guard !isRunning else { return }
        var seen = Set(inputs.map { $0.standardizedFileURL.path })
        for url in urls {
            let normalized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: normalized.path), !seen.contains(normalized.path) else { continue }
            inputs.append(normalized)
            seen.insert(normalized.path)
        }
        if archiveName.isEmpty, let first = inputs.first {
            archiveName = first.deletingPathExtension().lastPathComponent
        }
        if destinationURL == nil, let first = inputs.first {
            setDestination(first.deletingLastPathComponent())
        }
        state = .idle
        outputURL = nil
        detail = inputs.isEmpty
            ? AppLocalization.text("添加文件或文件夹以开始")
            : AppLocalization.format("已选择 %d 个项目", inputs.count)
    }

    public func removeInput(_ url: URL) {
        guard !isRunning else { return }
        inputs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        detail = inputs.isEmpty
            ? AppLocalization.text("添加文件或文件夹以开始")
            : AppLocalization.format("已选择 %d 个项目", inputs.count)
    }

    public func clearInputs() {
        guard !isRunning else { return }
        inputs.removeAll()
        outputURL = nil
        state = .idle
        progress = 0
        detail = AppLocalization.text("添加文件或文件夹以开始")
    }

    public func start() {
        guard worker == nil else { return }
        do {
            let plan = try makePlan()
            state = .compressing
            progress = 0
            outputURL = nil
            detail = AppLocalization.format("正在创建 %@ 压缩包…", format.label)
            worker = Task { [weak self] in
                guard let self else { return }
                var workspace: SecureCompressionWorkspace?
                self.runtimeSpaceFailure = nil
                self.runtimeCapacityFailure = false
                do {
                    let validationTask = Task.detached(priority: .userInitiated) {
                        try CompressionInputSecurity.validate(
                            inputs: plan.inputs,
                            outputURL: plan.desiredOutputURL,
                            fileManager: FileManager(),
                            shouldCancel: { Task.isCancelled }
                        )
                    }
                    let summary = try await withTaskCancellationHandler {
                        try await validationTask.value
                    } onCancel: {
                        validationTask.cancel()
                    }
                    guard !Task.isCancelled else { throw ArchiveEngineError.cancelled }

                    var requiredSpace: Int64
                    switch plan.format {
                    case .tar:
                        requiredSpace = summary.estimatedTarArchiveSize
                    case .tarGzip, .tarBzip2, .tarXz:
                        requiredSpace = summary.estimatedTarArchiveSize
                        let doubled = requiredSpace.addingReportingOverflow(summary.totalLogicalSize)
                        guard !doubled.overflow else { throw CompressionInputSecurityError.sizeOverflow }
                        let wrapperPeak = summary.estimatedTarArchiveSize.addingReportingOverflow(
                            summary.estimatedTarArchiveSize
                        )
                        guard !wrapperPeak.overflow else { throw CompressionInputSecurityError.sizeOverflow }
                        requiredSpace = max(doubled.partialValue, wrapperPeak.partialValue)
                    default:
                        requiredSpace = summary.estimatedGenericArchiveSize
                    }
                    try ArchiveSecurity.validateAdditionalDiskSpace(required: requiredSpace, at: plan.destinationURL)

                    let secureWorkspace = try SecureCompressionWorkspace(
                        destinationDirectory: plan.destinationURL,
                        archiveFileName: plan.archiveFileName,
                        format: plan.format,
                        fileManager: self.fileManager
                    )
                    workspace = secureWorkspace
                    let stagedRequest = CompressionRequest(
                        inputs: plan.inputs,
                        outputURL: secureWorkspace.archiveURL,
                        format: plan.format,
                        level: plan.level,
                        password: plan.password
                    )
                    let capacityMonitor = self.startCapacityMonitor(at: plan.destinationURL)
                    do {
                        try await self.engine.compress(stagedRequest) { [weak self] value in
                            Task { @MainActor in self?.progress = min(max(value, 0), 1) * 0.9 }
                        }
                        capacityMonitor.cancel()
                        await capacityMonitor.value
                        if let capacityError = self.consumeRuntimeCapacityError() { throw capacityError }
                    } catch {
                        capacityMonitor.cancel()
                        await capacityMonitor.value
                        if let capacityError = self.consumeRuntimeCapacityError() { throw capacityError }
                        throw error
                    }
                    guard !Task.isCancelled else { throw ArchiveEngineError.cancelled }
                    try ArchiveSecurity.validateAdditionalDiskSpace(required: 0, at: plan.destinationURL)
                    self.detail = AppLocalization.text("正在校验新压缩包…")
                    try await self.engine.verify(stagedRequest) { [weak self] value in
                        Task { @MainActor in self?.progress = 0.9 + min(max(value, 0), 1) * 0.1 }
                    }
                    guard !Task.isCancelled else { throw ArchiveEngineError.cancelled }

                    let publishedURL = try secureWorkspace.publish(to: plan.desiredOutputURL)
                    self.progress = 1
                    self.outputURL = publishedURL
                    self.state = .completed
                    self.detail = AppLocalization.format("压缩完成 · %@", publishedURL.lastPathComponent)
                } catch ArchiveEngineError.cancelled {
                    self.state = .cancelled
                    self.progress = 0
                    self.detail = AppLocalization.text("用户已取消")
                } catch {
                    self.state = .failed
                    self.progress = 0
                    self.detail = error.localizedDescription
                    self.presentedError = error.localizedDescription
                }
                workspace?.remove()
                self.runtimeSpaceFailure = nil
                self.runtimeCapacityFailure = false
                self.password = ""
                self.worker = nil
            }
        } catch {
            presentedError = error.localizedDescription
        }
    }

    public func cancel() {
        guard isRunning else { return }
        worker?.cancel()
        engine.cancel()
    }

    private struct CompressionPlan: Sendable {
        let inputs: [URL]
        let destinationURL: URL
        let archiveFileName: String
        let desiredOutputURL: URL
        let format: CompressionFormat
        let level: CompressionLevel
        let password: String?
    }

    private func makePlan() throws -> CompressionPlan {
        guard !inputs.isEmpty else { throw CompressionError.noInput }
        guard let destinationURL else { throw CompressionError.destinationUnavailable }
        let resolvedDestination = destinationURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedDestination.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isWritableFile(atPath: resolvedDestination.path) else {
            throw CompressionError.destinationUnavailable
        }
        guard let fileName = ArchiveUtilities.archiveFileName(baseName: archiveName, format: format) else {
            throw CompressionError.invalidName
        }
        if format.requiresSingleRegularFile {
            guard inputs.count == 1, Self.isRegularFileWithoutFollowingLinks(inputs[0]) else {
                throw CompressionError.singleRegularFileRequired
            }
        }
        let suppliedPassword = password.isEmpty ? nil : password
        if suppliedPassword != nil && !format.supportsPassword { throw CompressionError.passwordUnsupported }
        if let suppliedPassword, !ArchivePasswordPolicy.isValid(suppliedPassword) {
            throw CompressionError.invalidPassword
        }
        if format == .zip, let suppliedPassword, !suppliedPassword.unicodeScalars.allSatisfy(\.isASCII) {
            throw CompressionError.zipPasswordRequiresASCII
        }
        let desired = resolvedDestination.appendingPathComponent(fileName, isDirectory: false)
        return CompressionPlan(
            inputs: inputs,
            destinationURL: resolvedDestination,
            archiveFileName: fileName,
            desiredOutputURL: desired,
            format: format,
            level: level,
            password: suppliedPassword
        )
    }

    private static func isRegularFileWithoutFollowingLinks(_ url: URL) -> Bool {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        return result == 0 && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private func startCapacityMonitor(at destination: URL) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
                guard let self, self.isRunning else { return }
                do {
                    let available = try ArchiveSecurity.availableCapacity(at: destination)
                    if available < ArchiveSecurity.safetyReserve {
                        self.runtimeSpaceFailure = available
                        self.engine.cancel()
                        return
                    }
                } catch {
                    self.runtimeCapacityFailure = true
                    self.engine.cancel()
                    return
                }
            }
        }
    }

    private func consumeRuntimeCapacityError() -> Error? {
        if let available = runtimeSpaceFailure {
            runtimeSpaceFailure = nil
            return ArchiveSecurityError.insufficientSpace(
                required: ArchiveSecurity.safetyReserve,
                available: available
            )
        }
        if runtimeCapacityFailure {
            runtimeCapacityFailure = false
            return ExtractionSecuritySupportError.capacityUnavailable
        }
        return nil
    }
}
