import Foundation
import Combine

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
            let request = try makeRequest()
            state = .compressing
            progress = 0
            outputURL = nil
            detail = AppLocalization.format("正在创建 %@ 压缩包…", format.label)
            worker = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.engine.compress(request) { [weak self] value in
                        Task { @MainActor in self?.progress = min(max(value, 0), 1) }
                    }
                    guard !Task.isCancelled else { throw ArchiveEngineError.cancelled }
                    self.progress = 1
                    self.outputURL = request.outputURL
                    self.state = .completed
                    self.detail = AppLocalization.format("压缩完成 · %@", request.outputURL.lastPathComponent)
                } catch ArchiveEngineError.cancelled {
                    try? self.fileManager.removeItem(at: request.outputURL)
                    self.state = .cancelled
                    self.progress = 0
                    self.detail = AppLocalization.text("用户已取消")
                } catch {
                    try? self.fileManager.removeItem(at: request.outputURL)
                    self.state = .failed
                    self.progress = 0
                    self.detail = error.localizedDescription
                    self.presentedError = error.localizedDescription
                }
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

    private func makeRequest() throws -> CompressionRequest {
        guard !inputs.isEmpty else { throw CompressionError.noInput }
        guard let destinationURL else { throw CompressionError.destinationUnavailable }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isWritableFile(atPath: destinationURL.path) else {
            throw CompressionError.destinationUnavailable
        }
        guard let fileName = ArchiveUtilities.archiveFileName(baseName: archiveName, format: format) else {
            throw CompressionError.invalidName
        }
        if format.requiresSingleRegularFile {
            guard inputs.count == 1,
                  (try? inputs[0].resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw CompressionError.singleRegularFileRequired
            }
        }
        let suppliedPassword = password.isEmpty ? nil : password
        if suppliedPassword != nil && !format.supportsPassword { throw CompressionError.passwordUnsupported }
        if format == .zip, let suppliedPassword, !suppliedPassword.unicodeScalars.allSatisfy(\.isASCII) {
            throw CompressionError.zipPasswordRequiresASCII
        }
        let desired = destinationURL.appendingPathComponent(fileName, isDirectory: false)
        let output = ArchiveUtilities.uniqueURL(for: desired, fileManager: fileManager)
        let outputPath = output.standardizedFileURL.path
        for input in inputs {
            if (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let inputPath = input.standardizedFileURL.path
                if outputPath == inputPath || outputPath.hasPrefix(inputPath.hasSuffix("/") ? inputPath : inputPath + "/") {
                    throw CompressionError.outputInsideInput
                }
            }
        }
        return CompressionRequest(inputs: inputs, outputURL: output, format: format, level: level, password: suppliedPassword)
    }
}
