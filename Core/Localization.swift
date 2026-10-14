import Foundation

/// Uses the application's standard `Localizable.strings` table. Keeping this
/// wrapper for dynamically constructed labels prevents them from bypassing the
/// same macOS localization mechanism that SwiftUI uses for string literals.
enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    /// Formats a string that contains decimals, such as "%.1f°C", using the user's
    /// locale, so the decimal separator is localized.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    /// Formats a string whose numbers are whole counts, such as fan speeds. The
    /// locale is left out on purpose. With it, `%d` groups digits with the locale's
    /// separator, which showed fan speeds as "4,500 RPM".
    static func formatCount(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }
}
