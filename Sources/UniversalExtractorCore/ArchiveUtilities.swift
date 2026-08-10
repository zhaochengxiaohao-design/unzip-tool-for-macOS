import Foundation

public enum ArchiveUtilities {
    private static let compoundExtensions = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.lzma", ".tgz", ".tbz2", ".txz"
    ]

    public static func outputBaseName(for url: URL) -> String {
        var name = url.lastPathComponent
        let lower = name.lowercased()

        if let range = lower.range(of: #"\.part\d+\.rar$"#, options: .regularExpression) {
            name.removeLast(lower.distance(from: range.lowerBound, to: lower.endIndex))
            return nonempty(name)
        }
        if let range = lower.range(of: #"\.(7z|zip)\.\d{3,}$"#, options: .regularExpression) {
            name.removeLast(lower.distance(from: range.lowerBound, to: lower.endIndex))
            return nonempty(name)
        }
        for ext in compoundExtensions where lower.hasSuffix(ext) {
            name.removeLast(ext.count)
            return nonempty(name)
        }
        let deleted = (name as NSString).deletingPathExtension
        return nonempty(deleted)
    }

    public static func normalizedFirstVolume(for url: URL, fileManager: FileManager = .default) throws -> URL {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        let directory = url.deletingLastPathComponent()

        if let match = capture(in: lower, pattern: #"^(.*\.part)(\d+)(\.rar)$"#),
           let number = Int(match[2]), number > 1 {
            let width = match[2].count
            let candidateName = String(name.prefix(match[1].count)) + String(format: "%0*d", width, 1) + String(name.suffix(match[3].count))
            let candidate = directory.appendingPathComponent(candidateName)
            guard fileManager.fileExists(atPath: candidate.path) else {
                throw ArchiveEngineError.missingVolume(AppLocalization.format("请先选择第 1 卷 %@", candidateName))
            }
            return candidate
        }

        if let match = capture(in: lower, pattern: #"^(.*\.(?:7z|zip)\.)(\d{3,})$"#),
           let number = Int(match[2]), number > 1 {
            let candidateName = String(name.prefix(match[1].count)) + String(repeating: "0", count: match[2].count - 1) + "1"
            let candidate = directory.appendingPathComponent(candidateName)
            guard fileManager.fileExists(atPath: candidate.path) else {
                throw ArchiveEngineError.missingVolume(AppLocalization.format("请先选择第 1 卷 %@", candidateName))
            }
            return candidate
        }

        return url
    }

    public static func uniqueURL(for desiredURL: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: desiredURL.path) else { return desiredURL }
        let parent = desiredURL.deletingLastPathComponent()
        let ext = desiredURL.pathExtension
        let base = ext.isEmpty ? desiredURL.lastPathComponent : desiredURL.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    private static func capture(in value: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }

    private static func nonempty(_ value: String) -> String {
        value.isEmpty ? AppLocalization.text("解压内容") : value
    }
}
