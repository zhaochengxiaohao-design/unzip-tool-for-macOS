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

public enum CompressionFormat: String, CaseIterable, Codable, Sendable {
    case sevenZip
    case zip
    case tar
    case tarGzip
    case tarBzip2
    case tarXz
    case gzip
    case bzip2
    case xz

    public var label: String {
        switch self {
        case .sevenZip: return "7Z"
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .tarGzip: return "TAR.GZ"
        case .tarBzip2: return "TAR.BZ2"
        case .tarXz: return "TAR.XZ"
        case .gzip: return "GZIP"
        case .bzip2: return "BZIP2"
        case .xz: return "XZ"
        }
    }

    public var fileExtension: String {
        switch self {
        case .sevenZip: return "7z"
        case .zip: return "zip"
        case .tar: return "tar"
        case .tarGzip: return "tar.gz"
        case .tarBzip2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .gzip: return "gz"
        case .bzip2: return "bz2"
        case .xz: return "xz"
        }
    }

    public var supportsPassword: Bool { self == .sevenZip || self == .zip }
    public var requiresSingleRegularFile: Bool { self == .gzip || self == .bzip2 || self == .xz }
}

public enum CompressionLevel: Int, CaseIterable, Codable, Sendable {
    case store = 0
    case fast = 1
    case normal = 5
    case maximum = 9

    public var label: String {
        switch self {
        case .store: return AppLocalization.text("仅存储")
        case .fast: return AppLocalization.text("快速")
        case .normal: return AppLocalization.text("标准")
        case .maximum: return AppLocalization.text("极限")
        }
    }
}

public struct CompressionRequest: Sendable {
    public let inputs: [URL]
    public let outputURL: URL
    public let format: CompressionFormat
    public let level: CompressionLevel
    public let password: String?

    public init(inputs: [URL], outputURL: URL, format: CompressionFormat, level: CompressionLevel, password: String?) {
        self.inputs = inputs
        self.outputURL = outputURL
        self.format = format
        self.level = level
        self.password = password
    }
}

public enum ArchivePasswordPolicy {
    public static let maximumUnicodeScalarCount = 256
    public static let maximumUTF8ByteCount = 1_024

    public static func isValid(_ password: String) -> Bool {
        guard !password.isEmpty,
              password.unicodeScalars.count <= maximumUnicodeScalarCount,
              password.utf8.count <= maximumUTF8ByteCount else { return false }
        return password.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}

public enum CompressionState: String, Sendable {
    case idle
    case compressing
    case completed
    case failed
    case cancelled
}

public enum CompressionError: LocalizedError, Equatable, Sendable {
    case noInput
    case invalidName
    case destinationUnavailable
    case singleRegularFileRequired
    case passwordUnsupported
    case zipPasswordRequiresASCII
    case invalidPassword
    case outputInsideInput

    public var errorDescription: String? {
        switch self {
        case .noInput: return AppLocalization.text("请先添加要压缩的文件或文件夹。")
        case .invalidName: return AppLocalization.text("请输入有效的压缩包名称。")
        case .destinationUnavailable: return AppLocalization.text("请选择可用的压缩包保存目录。")
        case .singleRegularFileRequired: return AppLocalization.text("GZIP、BZIP2 和 XZ 只能压缩一个普通文件；如需压缩多个项目，请选择 TAR.GZ、TAR.BZ2 或 TAR.XZ。")
        case .passwordUnsupported: return AppLocalization.text("所选格式不支持密码保护。")
        case .zipPasswordRequiresASCII: return AppLocalization.text("受 ZIP 格式兼容性限制，ZIP 密码仅支持英文、数字和常用半角符号；如需使用中文密码，请选择 7Z。")
        case .invalidPassword: return AppLocalization.text("密码不能为空、包含换行或其他控制字符，且不能超过 256 个字符。")
        case .outputInsideInput: return AppLocalization.text("压缩包不能保存到正在压缩的文件夹内部，请选择其上级目录或其他目录。")
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
    public var mode: String?
    public var hardLinkTarget: String?
    public var deviceMajor: Int?
    public var deviceMinor: Int?

    public init(
        path: String,
        size: Int64?,
        attributes: String?,
        symbolicLinkTarget: String?,
        mode: String? = nil,
        hardLinkTarget: String? = nil,
        deviceMajor: Int? = nil,
        deviceMinor: Int? = nil
    ) {
        self.path = path
        self.size = size
        self.attributes = attributes
        self.symbolicLinkTarget = symbolicLinkTarget
        self.mode = mode
        self.hardLinkTarget = hardLinkTarget
        self.deviceMajor = deviceMajor
        self.deviceMinor = deviceMinor
    }
}

public struct ArchiveInspection: Equatable, Sendable {
    public var format: String
    public var physicalSize: Int64?
    public var totalUncompressedSize: Int64
    public var encrypted: Bool
    public var entries: [ArchiveEntry]
    public var entryCount: Int
    public var hasUnknownEntrySizes: Bool
    public var uncompressedSizeOverflowed: Bool
    public var listingIsAmbiguous: Bool

    public init(
        format: String,
        physicalSize: Int64?,
        totalUncompressedSize: Int64,
        encrypted: Bool,
        entries: [ArchiveEntry],
        entryCount: Int? = nil,
        hasUnknownEntrySizes: Bool? = nil,
        uncompressedSizeOverflowed: Bool = false,
        listingIsAmbiguous: Bool = false
    ) {
        self.format = format
        self.physicalSize = physicalSize
        self.totalUncompressedSize = totalUncompressedSize
        self.encrypted = encrypted
        self.entries = entries
        self.entryCount = entryCount ?? entries.count
        self.hasUnknownEntrySizes = hasUnknownEntrySizes ?? entries.contains(where: { $0.size == nil })
        self.uncompressedSizeOverflowed = uncompressedSizeOverflowed
        self.listingIsAmbiguous = listingIsAmbiguous
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
    case invalidPassword
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
        case .invalidPassword: return AppLocalization.text("密码不能为空、包含换行或其他控制字符，且不能超过 256 个字符。")
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

public protocol ArchiveCompressionEngine: AnyObject {
    func compress(_ request: CompressionRequest, progress: @escaping @Sendable (Double) -> Void) async throws
    func verify(_ request: CompressionRequest, progress: @escaping @Sendable (Double) -> Void) async throws
    func cancel()
}
