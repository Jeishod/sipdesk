import Foundation

/// Thread-safe lookup is shared by SIPCore, the worker and both UI frameworks.
/// Catalogs are explicit JSON resources, never Foundation's implicit language fallback.
public enum Localization {
    public static let didChange = Notification.Name("SIPDesk.languageDidChange")
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var language = AppLanguage.en
        var catalogs: [AppLanguage: [String: String]] = [:]
    }
    private static let state = State()
    public static var language: AppLanguage { state.lock.withLock { state.language } }
    public static var locale: Locale { Locale(identifier: language == .pt ? "pt_PT" : language.rawValue) }
    public static func setLanguage(_ language: AppLanguage) {
        state.lock.withLock { state.language = AppLanguage.resolve(selection: language) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
    public static func catalog(_ language: AppLanguage) throws -> [String: String] {
        if let cached = state.lock.withLock({ state.catalogs[language] }) { return cached }
        guard let url = Bundle.module.url(forResource: language.rawValue, withExtension: "json", subdirectory: "Localization") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        state.lock.withLock { state.catalogs[language] = values }
        return values
    }
    public static func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\{[0-9]+\}|%(?:[0-9]+\$)?[-+0-9.]*[df@]"#)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
    }
    /// Only application-owned C warning labels are translated; native detail is opaque.
    public static func engineMessage(_ message: String) -> String {
        for prefix in ["Audio playback", "Audio capture", "Audio negotiation", "SIP transport", "Audio recovery"] {
            let marker = prefix + ": "
            if message.hasPrefix(marker) { return text(prefix + ": {0}", arguments: [String(message.dropFirst(marker.count))]) }
        }
        return message
    }

    /// Re-render already displayed local messages; unmatched PBX payloads stay verbatim.
    public static func relocalize(_ text: String, from source: AppLanguage) -> String {
        guard let catalog = try? catalog(source) else { return text }
        if let key = catalog.first(where: { $0.value == text })?.key { return self.text(key) }
        for (key, template) in catalog where template.contains("{0}") {
            let parts = template.components(separatedBy: "{0}")
            guard parts.count == 2 else { continue }
            let pattern = "^" + NSRegularExpression.escapedPattern(for: template)
                .replacingOccurrences(of: NSRegularExpression.escapedPattern(for: "{0}"), with: "(.*?)")
                .replacingOccurrences(of: NSRegularExpression.escapedPattern(for: "{1}"), with: "(.*)") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            var args = (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            // Only this local log embeds another local title. Never reinterpret PBX detail.
            if key == "Call ended · {0} · {1}", args.count == 2,
               let outcome = ["Completed", "Missed", "Declined", "Cancelled", "Failed"].first(where: { catalog[$0] == args[1] }) {
                args[1] = self.text(outcome)
            }
            return self.text(key, arguments: args)
        }
        return text
    }

    public static func text(_ key: String, arguments: [String] = []) -> String {
        var result = (try? catalog(language)[key]) ?? (try? catalog(.en)[key]) ?? key
        // One pass: substituted server text cannot accidentally become another placeholder.
        let regex = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let indexRange = Range(match.range(at: 1), in: result), let index = Int(result[indexRange]), arguments.indices.contains(index), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: arguments[index])
        }
        return result
    }
}

public func L(_ key: String, _ arguments: String...) -> String { Localization.text(key, arguments: arguments) }
