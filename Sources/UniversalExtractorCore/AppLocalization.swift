import Foundation

/// Shared localization lookup. Release builds place Localizable.strings in the main app bundle.
public enum AppLocalization {
    public static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
