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
    /// 每次顺序队列完全空闲后递增，供 Finder 静默入口可靠结束应用生命周期。
    @Published public private(set) var queueCompletionGeneration = 0

    private let engine: ArchiveEngine
    private let fileManager: FileManager
    private var worker: Task<Void, Never>?
    private var currentJobID: UUID?
    private var passwordContinuation: CheckedContinuation<String?, Never>?
    private var collisionContinuation: CheckedContinuation<CollisionPolicy, Never>?
    private var cancellationTokens: [UUID: ExtractionCancellationToken] = [:]
    private var runtimeSpaceFailures: [UUID: Int64] = [:]
    private var runtimeCapacityFailures: Set<UUID> = []

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

    deinit {
        worker?.cancel()
        cancellationTokens.values.forEach { $0.cancel() }
        engine.cancel()
    }

    public func setDestination(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        destinationURL = resolved
        UserDefaults.standard.set(resolved.path, forKey: "lastDestination")
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
                let resolvedDestination = destination(url).resolvingSymlinksInPath().standardizedFileURL
                let job = ArchiveJob(sourceURL: url, outputMode: outputMode, destinationURL: resolvedDestination)
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
            cancellationTokens[jobID]?.cancel()
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
            if self.jobs.contains(where: { $0.state == .queued }) {
                self.startWorkerIfNeeded()
            } else {
                self.queueCompletionGeneration = self.queueCompletionGeneration == Int.max
                    ? 0
                    : self.queueCompletionGeneration + 1
            }
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

    private func process(jobID: UUID, destination requestedDestination: URL) async {
        guard let job = job(jobID) else { return }
        let cancellationToken = ExtractionCancellationToken()
        cancellationTokens[jobID] = cancellationToken
        let destination: URL
        let workspace: SecureExtractionWorkspace
        do {
            let fileManager = self.fileManager
            let prepared = try await Task.detached(priority: .userInitiated) {
                try cancellationToken.check()
                let trustedDestination = try SecurePOSIXFileSystem.trustedCanonicalDirectory(
                    requestedDestination
                )
                let workspace = try SecureExtractionWorkspace(
                    parent: trustedDestination,
                    jobID: jobID,
                    fileManager: fileManager
                )
                return (trustedDestination, workspace)
            }.value
            destination = prepared.0
            workspace = prepared.1
        } catch {
            cancellationTokens.removeValue(forKey: jobID)
            if error as? ArchiveEngineError == .cancelled {
                update(jobID, state: .cancelled, progress: 0, detail: AppLocalization.text("用户已取消"))
            } else {
                update(jobID, state: .failed, progress: 0, detail: error.localizedDescription)
            }
            return
        }
        let staging = workspace.stagingURL
        var password: String?
        var terminalState: JobState = .failed
        var terminalProgress = 0.0
        var terminalDetail = AppLocalization.text("未知错误")
        var preserveWorkspaceForRecovery = false

        do {
            try cancellationToken.check()
            update(jobID, state: .inspecting, progress: 0, detail: AppLocalization.text("正在根据文件内容识别格式…"))
            let sourceURL = job.sourceURL
            let preparedSource = try await Task.detached(priority: .userInitiated) {
                try cancellationToken.check()
                let originalQuarantine = try QuarantinePropagation.metadata(at: sourceURL)
                let archive = try workspace.snapshotArchive(sourceURL, cancellationToken: cancellationToken)
                let snapshotQuarantine = try QuarantinePropagation.metadata(at: archive)
                try cancellationToken.check()
                return PreparedExtractionSource(
                    archiveURL: archive,
                    quarantineMetadata: originalQuarantine ?? snapshotQuarantine
                )
            }.value
            let archive = preparedSource.archiveURL

            var inspection: ArchiveInspection
            while true {
                do {
                    inspection = try await engine.inspect(archive, password: password)
                    try cancellationToken.check()
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

            try await Task.detached(priority: .userInitiated) {
                try cancellationToken.check()
                try ArchiveSecurity.validateInspection(
                    inspection,
                    shouldCancel: { cancellationToken.isCancelled || Task.isCancelled }
                )
                try ArchiveSecurity.validateDiskSpace(for: inspection, at: destination)
                try cancellationToken.check()
            }.value
            updateFormat(jobID, inspection.format.isEmpty ? AppLocalization.text("自动识别") : inspection.format)

            while true {
                do {
                    try cancellationToken.check()
                    update(jobID, state: .testing, progress: 0, detail: AppLocalization.text("正在校验压缩包完整性…"))
                    try await engine.test(archive, password: password) { [weak self] progress in
                        Task { @MainActor in self?.updateProgress(jobID, progress: progress * 0.15) }
                    }
                    try cancellationToken.check()
                    break
                } catch ArchiveEngineError.passwordRequired, ArchiveEngineError.wrongPassword {
                    password = await requestPassword(jobID: jobID, archiveName: job.displayName, message: AppLocalization.text("密码错误，请重新输入。"))
                    guard password != nil else { throw ArchiveEngineError.cancelled }
                }
            }

            update(jobID, state: .extracting, progress: 0.15, detail: AppLocalization.text("正在解压…"))
            try await extractLayers(
                archive: archive,
                inspection: inspection,
                to: staging,
                password: password,
                jobID: jobID,
                depth: 0,
                progressStart: 0.15,
                progressEnd: 0.95,
                workspace: workspace,
                cancellationToken: cancellationToken
            )
            let fileManager = self.fileManager
            let allowSymbolicLinks = job.outputMode == .separateFolder
            try await Task.detached(priority: .userInitiated) {
                try cancellationToken.check()
                try ArchiveSecurity.validateExtractedTree(
                    at: staging,
                    allowSymbolicLinks: allowSymbolicLinks,
                    fileManager: fileManager,
                    shouldCancel: { cancellationToken.isCancelled || Task.isCancelled }
                )
                try cancellationToken.check()
                try QuarantinePropagation.apply(
                    preparedSource.quarantineMetadata,
                    to: staging,
                    fileManager: fileManager,
                    shouldCancel: { cancellationToken.isCancelled || Task.isCancelled }
                )
                try cancellationToken.check()
            }.value
            update(jobID, state: .finalizing, progress: 0.96, detail: AppLocalization.text("正在整理输出文件…"))

            let finalURL: URL
            switch job.outputMode {
            case .separateFolder:
                let desired = destination.appendingPathComponent(ArchiveUtilities.outputBaseName(for: job.sourceURL), isDirectory: true)
                finalURL = try await Task.detached(priority: .userInitiated) {
                    try cancellationToken.check()
                    return try SecurePOSIXFileSystem.moveToUniqueDestination(
                        from: staging,
                        desired: desired,
                        shouldCancel: { cancellationToken.isCancelled || Task.isCancelled }
                    )
                }.value
            case .directlyIntoDestination:
                var policy: CollisionPolicy = .keepBoth
                let hasCollisions = try await Task.detached(priority: .userInitiated) {
                    try cancellationToken.check()
                    return try FileMerger.hasCollisions(
                        from: staging,
                        into: destination,
                        fileManager: fileManager,
                        shouldCancel: { cancellationToken.isCancelled || Task.isCancelled }
                    )
                }.value
                if hasCollisions {
                    policy = await requestCollisionChoice(jobID: jobID, archiveName: job.displayName)
                    guard policy != .cancel else { throw ArchiveEngineError.cancelled }
                }
                try cancellationToken.check()
                try await Task.detached(priority: .userInitiated) {
                    try FileMerger.merge(
                        from: staging,
                        into: destination,
                        policy: policy,
                        fileManager: fileManager,
                        shouldCancel: { cancellationToken.isCancelled || Task.isCancelled }
                    )
                }.value
                finalURL = destination
            }

            updateOutput(jobID, outputURL: finalURL)
            terminalState = .completed
            terminalProgress = 1
            terminalDetail = AppLocalization.text("解压完成")
        } catch ArchiveEngineError.cancelled {
            terminalState = .cancelled
            terminalProgress = 0
            terminalDetail = AppLocalization.text("用户已取消")
        } catch {
            terminalState = .failed
            terminalProgress = 0
            let phase = jobs.first(where: { $0.id == jobID })?.state.label ?? AppLocalization.text("失败")
            terminalDetail = "\(phase): \(error.localizedDescription)"
            if let supportError = error as? ExtractionSecuritySupportError,
               case .rollbackFailed = supportError {
                preserveWorkspaceForRecovery = true
            }
        }

        password = nil
        if !preserveWorkspaceForRecovery {
            do {
                try await Task.detached(priority: .utility) { try workspace.remove() }.value
            } catch {
                if terminalState == .completed {
                    terminalState = .failed
                    terminalProgress = 0
                    terminalDetail = error.localizedDescription
                }
            }
        }
        cancellationTokens.removeValue(forKey: jobID)
        runtimeSpaceFailures.removeValue(forKey: jobID)
        runtimeCapacityFailures.remove(jobID)
        update(jobID, state: terminalState, progress: terminalProgress, detail: terminalDetail)
    }

    private func extractLayers(
        archive: URL,
        inspection: ArchiveInspection,
        to output: URL,
        password: String?,
        jobID: UUID,
        depth: Int,
        progressStart: Double,
        progressEnd: Double,
        workspace: SecureExtractionWorkspace,
        cancellationToken: ExtractionCancellationToken
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try cancellationToken.check()
            try ArchiveSecurity.validateDiskSpace(for: inspection, at: workspace.rootURL)
        }.value
        let isWrapper = Self.singleFileCompressionFormats.contains(inspection.format.lowercased())
        let layerEnd = isWrapper && depth < 3
            ? progressStart + (progressEnd - progressStart) * 0.45
            : progressEnd

        let capacityMonitor = startCapacityMonitor(at: workspace.rootURL, jobID: jobID)
        do {
            try await engine.extract(archive, to: output, password: password) { [weak self] progress in
                Task { @MainActor in
                    self?.updateProgress(jobID, progress: progressStart + progress * (layerEnd - progressStart))
                }
            }
            capacityMonitor.cancel()
            await capacityMonitor.value
            if let diskError = consumeRuntimeCapacityError(jobID) { throw diskError }
        } catch {
            capacityMonitor.cancel()
            await capacityMonitor.value
            if let diskError = consumeRuntimeCapacityError(jobID) { throw diskError }
            throw error
        }
        try cancellationToken.check()

        guard isWrapper, depth < 3 else { return }
        let fileManager = self.fileManager
        let nestedArchiveCandidate: URL? = try await Task.detached(priority: .userInitiated, operation: { () throws -> URL? in
            try cancellationToken.check()
            let items = try fileManager.contentsOfDirectory(
                at: output,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard items.count == 1, let item = items.first,
                  try SecurePOSIXFileSystem.information(at: item).kind == .regular else { return nil }
            return item
        }).value
        guard let nestedArchive = nestedArchiveCandidate else { return }

        let nestedInspection: ArchiveInspection
        do {
            nestedInspection = try await engine.inspect(nestedArchive, password: nil)
        } catch ArchiveEngineError.unsupported {
            return
        }
        try await Task.detached(priority: .userInitiated) {
            try cancellationToken.check()
            try ArchiveSecurity.validateInspection(
                nestedInspection,
                shouldCancel: { cancellationToken.isCancelled || Task.isCancelled }
            )
            try ArchiveSecurity.validateDiskSpace(for: nestedInspection, at: workspace.rootURL)
            try cancellationToken.check()
        }.value

        let nextOutput = try await Task.detached(priority: .userInitiated) {
            try cancellationToken.check()
            return try workspace.makeLayerDirectory(depth: depth + 1)
        }.value
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
                progressEnd: progressEnd,
                workspace: workspace,
                cancellationToken: cancellationToken
            )
            try await Task.detached(priority: .userInitiated) {
                try cancellationToken.check()
                try fileManager.removeItem(at: output)
                try SecurePOSIXFileSystem.moveNoReplace(from: nextOutput, to: output)
            }.value
        } catch {
            _ = try? await Task.detached(priority: .utility) {
                if try SecurePOSIXFileSystem.informationIfPresent(at: nextOutput) != nil {
                    try fileManager.removeItem(at: nextOutput)
                }
            }.value
            throw error
        }
    }

    private static let singleFileCompressionFormats: Set<String> = [
        "gzip", "bzip2", "xz", "lzma", "z", "zstd"
    ]

    private func startCapacityMonitor(at destination: URL, jobID: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }
                guard let self, self.currentJobID == jobID else { return }
                do {
                    let available = try ArchiveSecurity.availableCapacity(at: destination)
                    if available < ArchiveSecurity.safetyReserve {
                        self.runtimeSpaceFailures[jobID] = available
                        self.engine.cancel()
                        return
                    }
                } catch {
                    self.runtimeCapacityFailures.insert(jobID)
                    self.engine.cancel()
                    return
                }
            }
        }
    }

    private func consumeRuntimeCapacityError(_ jobID: UUID) -> Error? {
        if let available = runtimeSpaceFailures.removeValue(forKey: jobID) {
            return ArchiveSecurityError.insufficientSpace(
                required: ArchiveSecurity.safetyReserve,
                available: available
            )
        }
        if runtimeCapacityFailures.remove(jobID) != nil {
            return ExtractionSecuritySupportError.capacityUnavailable
        }
        return nil
    }

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
