import Foundation

/// The build's version, shown on the faceplate. Mirrors the Mac build's
/// MARKETING_VERSION; the `x` suffix marks the Windows/Linux port the way
/// `lr` and `cr` mark Local and Cloud.
public enum AppInfo {
    public static let name = "DoublEnder"
    public static let version = "2.6.0x"
    /// Filename prefix when Settings leaves it empty.
    public static let defaultRecordingPrefix = "DoublEnder"
}

/// Shared version-string parsing. Ported unchanged from the Mac build.
public enum VersionFormatting {

    /// Strip pre-release suffixes and trailing letter build flavours (`lr`, `cr`, `x`).
    /// `"1.6.28lr"` → `"1.6.28"`, `"v1.0.0-beta.2"` → `"1.0.0"`.
    public static func numericVersion(_ raw: String) -> String {
        let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        if let range = stripped.range(of: #"[^0-9.]"#, options: .regularExpression) {
            return String(stripped[..<range.lowerBound])
        }
        return stripped
    }

    /// Split `"1.6.18lr"` → `("1.6.18", "lr")`.
    public static func splitSuffix(_ raw: String) -> (numeric: String, suffix: String) {
        guard let range = raw.range(of: #"[A-Za-z]+$"#, options: .regularExpression) else {
            return (raw, "")
        }
        return (String(raw[..<range.lowerBound]), String(raw[range]))
    }
}
