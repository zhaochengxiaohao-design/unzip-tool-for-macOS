import Foundation

public enum JobState: String, Codable, Sendable {
    case queued
    case inspecting
    case waitingForPassword
    case testing
    case extracting
    case waitingForCollisionChoice
    case finalizing
    case completed
    case failed
    case cancelled

    public var label: String {
        switch self {
        case .queued: return AppLocalization.text("等待中")
        case .inspecting: return AppLocalization.text("正在识别")
        case .waitingForPassword: return AppLocalization.text("等待密码")
        case .testing: return AppLocalization.text("正在校验")
        case .extracting: return AppLocalization.text("正在解压")
        case .waitingForCollisionChoice: return AppLocalization.text("等待重名处理")
        case .finalizing: return AppLocalization.text("正在整理文件")
        case .completed: return AppLocalization.text("已完成")
        case .failed: return AppLocalization.text("失败")
        case .cancelled: return AppLocalization.text("已取消")
        }
    }

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

public enum OutputMode: String, CaseIterable, Codable, Sendable {
    case separateFolder
    case directlyIntoDestination

    public var label: String {
        switch self {
        case .separateFolder: return AppLocalization.text("每包单独文件夹")
        case .directlyIntoDestination: return AppLocalization.text("直接解到压缩包所在目录")
        }
    }
}

public enum CollisionPolicy: String, CaseIterable, Codable, Sendable {
    case overwrite
    case skip
    case keepBoth
    case cancel

    public var label: String {
        switch self {
        case .overwrite: return AppLocalization.text("覆盖已有文件")
        case .skip: return AppLocalization.text("跳过已有文件")
        case .keepBoth: return AppLocalization.text("保留两者")
        case .cancel: return AppLocalization.text("取消此任务")
        }
    }
}

public struct ArchiveJob: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let outputMode: OutputMode
    public let destinationURL: URL
    public var state: JobState
    public var progress: Double
    public var detail: String
    public var detectedFormat: String?
    public var outputURL: URL?

    public init(sourceURL: URL, outputMode: OutputMode, destinationURL: URL) {
        id = UUID()
        self.sourceURL = sourceURL
        self.outputMode = outputMode
        self.destinationURL = destinationURL
        state = .queued
        progress = 0
        detail = AppLocalization.format("等待处理 · 输出到 %@", destinationURL.lastPathComponent)
    }

    public var displayName: String { sourceURL.lastPathComponent }
}

public struct ArchiveEntry: Equatable, Sendable {
    public var path: String
    public var size: Int64?
    public var attributes: String?
    public var symbolicLinkTarget: String?

    public init(path: String, size: Int64?, attributes: String?, symbolicLinkTarget: String?) {
        self.path = path
        self.size = size
        self.attributes = attributes
        self.symbolicLinkTarget = symbolicLinkTarget
    }
}

public struct ArchiveInspection: Equatable, Sendable {
    public var format: String
    public var physicalSize: Int64?
    public var totalUncompressedSize: Int64
    public var encrypted: Bool
    public var entries: [ArchiveEntry]

    public init(format: String, physicalSize: Int64?, totalUncompressedSize: Int64, encrypted: Bool, entries: [ArchiveEntry]) {
        self.format = format
        self.physicalSize = physicalSize
        self.totalUncompressedSize = totalUncompressedSize
        self.encrypted = encrypted
        self.entries = entries
    }
}

public enum ArchiveEngineError: LocalizedError, Equatable, Sendable {
    case engineUnavailable
    case unsupported
    case passwordRequired
    case wrongPassword
    case corrupt(String)
    case missingVolume(String)
    case cancelled
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable: return AppLocalization.text("找不到内置解压引擎，请重新构建应用。")
        case .unsupported: return AppLocalization.text("无法识别此文件，或该压缩格式暂不受支持。")
        case .passwordRequired: return AppLocalization.text("此压缩包需要密码。")
        case .wrongPassword: return AppLocalization.text("密码错误，请重试。")
        case .corrupt(let detail): return AppLocalization.format("压缩包已损坏或校验失败：%@", detail)
        case .missingVolume(let detail): return AppLocalization.format("分卷不完整：%@", detail)
        case .cancelled: return AppLocalization.text("任务已取消。")
        case .processFailed(let detail): return AppLocalization.format("解压引擎执行失败：%@", detail)
        }
    }
}

public protocol ArchiveEngine: AnyObject {
    func inspect(_ archive: URL, password: String?) async throws -> ArchiveInspection
    func test(_ archive: URL, password: String?, progress: @escaping @Sendable (Double) -> Void) async throws
    func extract(_ archive: URL, to destination: URL, password: String?, progress: @escaping @Sendable (Double) -> Void) async throws
    func cancel()
}
