import Foundation
import Combine

public struct PasswordRequest: Identifiable, Equatable {
    public let id = UUID()
    public let jobID: UUID
    public let archiveName: String
    public let message: String
}

public struct CollisionRequest: Identifiable, Equatable {
    public let id = UUID()
    public let jobID: UUID
    public let archiveName: String
}

@MainActor
public final class ExtractionCoordinator: ObservableObject {
    @Published public private(set) var jobs: [ArchiveJob] = []
    @Published public var destinationURL: URL?
    @Published public var passwordRequest: PasswordRequest?
    @Published public var collisionRequest: CollisionRequest?
    @Published public var presentedError: String?

    private let engine: ArchiveEngine
    private let fileManager: FileManager
    private var worker: Task<Void, Never>?
    private var currentJobID: UUID?
    private var passwordContinuation: CheckedContinuation<String?, Never>?
    private var collisionContinuation: CheckedContinuation<CollisionPolicy, Never>?

    public init(engine: ArchiveEngine = SevenZipEngine(), fileManager: FileManager = .default) {
        self.engine = engine
        self.fileManager = fileManager
        if let saved = UserDefaults.standard.string(forKey: "lastDestination"), !saved.isEmpty {
            let url = URL(fileURLWithPath: saved, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                destinationURL = url
            }
        }
    }

    deinit { worker?.cancel() }

    public func setDestination(_ url: URL) {
        destinationURL = url
        UserDefaults.standard.set(url.path, forKey: "lastDestination")
        startWorkerIfNeeded()
    }

    public func addFiles(_ urls: [URL], outputMode: OutputMode) {
        switch outputMode {
        case .separateFolder:
            guard let destinationURL else {
                presentedError = AppLocalization.text("请先选择输出目录。")
                return
            }
            enqueue(urls, outputMode: outputMode) { _ in destinationURL }
        case .directlyIntoDestination:
            enqueue(urls, outputMode: outputMode) { sourceURL in
                sourceURL.deletingLastPathComponent()
            }
        }
    }

    /// Finder 的“打开方式”或“服务”入口：每个压缩包解压到其所在目录。
    @discardableResult
    public func addExternalFiles(_ urls: [URL]) -> [UUID] {
        enqueue(urls, outputMode: .separateFolder) { sourceURL in
            sourceURL.deletingLastPathComponent()
        }
    }

    @discardableResult
    private func enqueue(_ urls: [URL], outputMode: OutputMode, destination: (URL) -> URL) -> [UUID] {
        var seen = Set(jobs.filter { !$0.state.isTerminal }.map { $0.sourceURL.standardizedFileURL.path })
        var addedIDs: [UUID] = []
        for originalURL in urls {
            do {
                let url = try ArchiveUtilities.normalizedFirstVolume(for: originalURL, fileManager: fileManager)
                let path = url.standardizedFileURL.path
                guard !seen.contains(path) else { continue }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                let job = ArchiveJob(sourceURL: url, outputMode: outputMode, destinationURL: destination(url))
                jobs.append(job)
                addedIDs.append(job.id)
                seen.insert(path)
            } catch {
                presentedError = error.localizedDescription
            }
        }
        startWorkerIfNeeded()
        return addedIDs
    }

    public func removeFinishedJobs() {
        jobs.removeAll { $0.state.isTerminal }
    }

    public func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if currentJobID == jobID {
            engine.cancel()
            passwordContinuation?.resume(returning: nil)
            passwordContinuation = nil
            collisionContinuation?.resume(returning: .cancel)
            collisionContinuation = nil
            passwordRequest = nil
            collisionRequest = nil
        } else if jobs[index].state == .queued {
            jobs[index].state = .cancelled
            jobs[index].detail = AppLocalization.text("用户已取消")
        }
    }

    public func submitPassword(_ password: String?) {
        let continuation = passwordContinuation
        passwordContinuation = nil
        passwordRequest = nil
        continuation?.resume(returning: password?.isEmpty == true ? nil : password)
    }

    public func submitCollisionPolicy(_ policy: CollisionPolicy) {
        let continuation = collisionContinuation
        collisionContinuation = nil
        collisionRequest = nil
        continuation?.resume(returning: policy)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, jobs.contains(where: { $0.state == .queued }) else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.processQueue()
            self.worker = nil
            if self.jobs.contains(where: { $0.state == .queued }) { self.startWorkerIfNeeded() }
        }
    }

    private func processQueue() async {
        while !Task.isCancelled,
              let index = jobs.firstIndex(where: { $0.state == .queued }) {
            let id = jobs[index].id
            let jobDestination = jobs[index].destinationURL
            currentJobID = id
            await process(jobID: id, destination: jobDestination)
            currentJobID = nil
        }
    }

    private func process(jobID: UUID, destination: URL) async {
        guard let job = job(jobID) else { return }
        let staging = destination.appendingPathComponent(".万能解压-临时-\(jobID.uuidString)", isDirectory: true)
        var password: String?

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            update(jobID, state: .inspecting, progress: 0, detail: AppLocalization.text("正在根据文件内容识别格式…"))

            var inspection: ArchiveInspection
            while true {
                do {
                    inspection = try await engine.inspect(job.sourceURL, password: password)
                    if inspection.encrypted && password == nil {
                        password = await requestPassword(jobID: jobID, archiveName: job.displayName, message: AppLocalization.text("此压缩包已加密，请输入密码。"))
                        guard password != nil else { throw ArchiveEngineError.cancelled }
                        continue
                    }
                    break
                } catch ArchiveEngineError.passwordRequired {
                    password = await requestPassword(jobID: jobID, archiveName: job.displayName, message: AppLocalization.text("此压缩包需要密码。"))
                    guard password != nil else { throw ArchiveEngineError.cancelled }
                } catch ArchiveEngineError.wrongPassword {
                    password = await requestPassword(jobID: jobID, archiveName: job.displayName, message: AppLocalization.text("密码错误，请重新输入。"))
                    guard password != nil else { throw ArchiveEngineError.cancelled }
                }
            }

            try ArchiveSecurity.validateInspection(inspection)
            try ArchiveSecurity.validateDiskSpace(for: inspection, at: destination)
            updateFormat(jobID, inspection.format.isEmpty ? AppLocalization.text("自动识别") : inspection.format)

            while true {
                do {
                    update(jobID, state: .testing, progress: 0, detail: AppLocalization.text("正在校验压缩包完整性…"))
                    try await engine.test(job.sourceURL, password: password) { [weak self] progress in
                        Task { @MainActor in self?.updateProgress(jobID, progress: progress * 0.15) }
                    }
                    break
                } catch ArchiveEngineError.passwordRequired, ArchiveEngineError.wrongPassword {
                    password = await requestPassword(jobID: jobID, archiveName: job.displayName, message: AppLocalization.text("密码错误，请重新输入。"))
                    guard password != nil else { throw ArchiveEngineError.cancelled }
                }
            }

            update(jobID, state: .extracting, progress: 0.15, detail: AppLocalization.text("正在解压…"))
            try await extractLayers(
                archive: job.sourceURL,
                inspection: inspection,
                to: staging,
                password: password,
                jobID: jobID,
                depth: 0,
                progressStart: 0.15,
                progressEnd: 0.95
            )
            try ArchiveSecurity.validateExtractedTree(at: staging, fileManager: fileManager)
            update(jobID, state: .finalizing, progress: 0.96, detail: AppLocalization.text("正在整理输出文件…"))

            let finalURL: URL
            switch job.outputMode {
            case .separateFolder:
                let desired = destination.appendingPathComponent(ArchiveUtilities.outputBaseName(for: job.sourceURL), isDirectory: true)
                finalURL = ArchiveUtilities.uniqueURL(for: desired, fileManager: fileManager)
                try fileManager.moveItem(at: staging, to: finalURL)
            case .directlyIntoDestination:
                var policy: CollisionPolicy = .keepBoth
                if try FileMerger.hasCollisions(from: staging, into: destination, fileManager: fileManager) {
                    policy = await requestCollisionChoice(jobID: jobID, archiveName: job.displayName)
                    guard policy != .cancel else { throw ArchiveEngineError.cancelled }
                }
                try FileMerger.merge(from: staging, into: destination, policy: policy, fileManager: fileManager)
                try? fileManager.removeItem(at: staging)
                finalURL = destination
            }

            updateOutput(jobID, outputURL: finalURL)
            update(jobID, state: .completed, progress: 1, detail: AppLocalization.text("解压完成"))
        } catch ArchiveEngineError.cancelled {
            try? fileManager.removeItem(at: staging)
            update(jobID, state: .cancelled, progress: 0, detail: AppLocalization.text("用户已取消"))
        } catch {
            try? fileManager.removeItem(at: staging)
            update(jobID, state: .failed, progress: 0, detail: error.localizedDescription)
        }
        password = nil
    }

    private func extractLayers(
        archive: URL,
        inspection: ArchiveInspection,
        to output: URL,
        password: String?,
        jobID: UUID,
        depth: Int,
        progressStart: Double,
        progressEnd: Double
    ) async throws {
        let isWrapper = Self.singleFileCompressionFormats.contains(inspection.format.lowercased())
        let layerEnd = isWrapper && depth < 3
            ? progressStart + (progressEnd - progressStart) * 0.45
            : progressEnd

        try await engine.extract(archive, to: output, password: password) { [weak self] progress in
            Task { @MainActor in
                self?.updateProgress(jobID, progress: progressStart + progress * (layerEnd - progressStart))
            }
        }

        guard isWrapper, depth < 3,
              let nestedArchive = try soleRegularFile(in: output) else { return }

        let nestedInspection: ArchiveInspection
        do {
            nestedInspection = try await engine.inspect(nestedArchive, password: nil)
        } catch ArchiveEngineError.unsupported {
            return
        }
        try ArchiveSecurity.validateInspection(nestedInspection)

        let nextOutput = output.deletingLastPathComponent()
            .appendingPathComponent("\(output.lastPathComponent)-层-\(depth + 1)", isDirectory: true)
        try fileManager.createDirectory(at: nextOutput, withIntermediateDirectories: false)
        do {
            update(jobID, state: .extracting, progress: layerEnd, detail: AppLocalization.format("正在展开组合压缩层 %d…", depth + 2))
            try await extractLayers(
                archive: nestedArchive,
                inspection: nestedInspection,
                to: nextOutput,
                password: nil,
                jobID: jobID,
                depth: depth + 1,
                progressStart: layerEnd,
                progressEnd: progressEnd
            )
            try fileManager.removeItem(at: output)
            try fileManager.moveItem(at: nextOutput, to: output)
        } catch {
            try? fileManager.removeItem(at: nextOutput)
            throw error
        }
    }

    private func soleRegularFile(in directory: URL) throws -> URL? {
        let items = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        guard items.count == 1, let item = items.first else { return nil }
        let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return item
    }

    private static let singleFileCompressionFormats: Set<String> = [
        "gzip", "bzip2", "xz", "lzma", "z", "zstd"
    ]

    private func requestPassword(jobID: UUID, archiveName: String, message: String) async -> String? {
        update(jobID, state: .waitingForPassword, progress: 0, detail: message)
        return await withCheckedContinuation { continuation in
            passwordContinuation = continuation
            passwordRequest = PasswordRequest(jobID: jobID, archiveName: archiveName, message: message)
        }
    }

    private func requestCollisionChoice(jobID: UUID, archiveName: String) async -> CollisionPolicy {
        update(jobID, state: .waitingForCollisionChoice, progress: 0.96, detail: AppLocalization.text("目标目录中存在同名文件"))
        return await withCheckedContinuation { continuation in
            collisionContinuation = continuation
            collisionRequest = CollisionRequest(jobID: jobID, archiveName: archiveName)
        }
    }

    private func job(_ id: UUID) -> ArchiveJob? { jobs.first(where: { $0.id == id }) }

    private func update(_ id: UUID, state: JobState, progress: Double, detail: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        jobs[index].progress = progress
        jobs[index].detail = detail
    }

    private func updateProgress(_ id: UUID, progress: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].progress = min(max(progress, 0), 1)
    }

    private func updateFormat(_ id: UUID, _ format: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].detectedFormat = format
    }

    private func updateOutput(_ id: UUID, outputURL: URL) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].outputURL = outputURL
    }
}
