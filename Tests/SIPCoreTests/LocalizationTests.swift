import XCTest
@testable import SIPCore

final class LocalizationTests: XCTestCase {
    func testEngineWarningPrefixesTranslateButDetailsStayVerbatim() {
        Localization.setLanguage(.ru)
        XCTAssertEqual(Localization.engineMessage("Audio capture: device error"), "Захват звука: device error")
        XCTAssertEqual(Localization.engineMessage("PBX custom warning"), "PBX custom warning")
        Localization.setLanguage(.en)
    }

    func testTechnicalExamplesRemainLiteralInEveryLanguage() throws {
        let tokens = ["sip://", "sips:", "user=phone", "host:port", "[::1]:5060", "user@domain.com"]
        for language in AppLanguage.translated {
            for (key, value) in try Localization.catalog(language) {
                for token in tokens where key.contains(token) {
                    XCTAssertTrue(value.contains(token), "\(language): \(token): \(key)")
                }
            }
        }
    }

    func testMessagesSwitchFromEveryLanguageIncludingNestedOutcome() {
        for language in AppLanguage.translated {
            Localization.setLanguage(language)
            let failure = L("SIP server error ({0}). {1}", "503", "PBX says {0}")
            let ended = L("Call ended · {0} · {1}", "200", CallOutcome.answered.title)
            Localization.setLanguage(.en)
            XCTAssertEqual(Localization.relocalize(failure, from: language), "SIP server error (503). PBX says {0}", language.rawValue)
            XCTAssertEqual(Localization.relocalize(ended, from: language), "Call ended · 200 · Completed", language.rawValue)
        }
    }

    func testStoredMessagesRelocalizeWithoutTranslatingServerPayload() {
        Localization.setLanguage(.ru)
        let old = L("SIP server error ({0}). {1}", "503", "PBX says {0}")
        Localization.setLanguage(.en)
        XCTAssertEqual(Localization.relocalize(old, from: .ru), "SIP server error (503). PBX says {0}")
        XCTAssertEqual(Localization.relocalize("Server-specific text", from: .ru), "Server-specific text")
        XCTAssertEqual(L("SIP server error ({0}). {1}", "500", "{0}"), "SIP server error (500). {0}")
    }

    func testEveryCatalogHasIdenticalNonemptyKeysAndPlaceholders() throws {
        let english = try Localization.catalog(.en)
        XCTAssertGreaterThan(english.count, 200)
        for language in AppLanguage.translated {
            let catalog = try Localization.catalog(language)
            XCTAssertEqual(Set(catalog.keys), Set(english.keys), language.rawValue)
            for (key, value) in catalog {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
                if language != .en {
                    let ordinary = ["Call", "Answer", "Decline", "Hold", "Resume", "History", "Language", "Settings", "Invalid SIP address."]
                    if ordinary.contains(key) { XCTAssertNotEqual(value, english[key], "Untranslated: \(language): \(key)") }
                }
                XCTAssertEqual(Localization.placeholders(value), Localization.placeholders(english[key]!), "\(language): \(key)")
            }
        }
        Localization.setLanguage(.ar)
        XCTAssertNotEqual(L("Call"), "Call")
        Localization.setLanguage(.en)
        XCTAssertEqual(L("Call"), "Call")
        XCTAssertEqual(L("unknown-key"), "unknown-key")
    }

    func testSelectionPersistsOnlyLanguageAndDefaultsToSystem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LanguagePreferenceStore(files: try LocalStore(directory: directory))
        XCTAssertEqual(try store.load(), .system)
        try store.save(.ar)
        XCTAssertEqual(try store.load(), .ar)
        let data = try Data(contentsOf: directory.appendingPathComponent("language.json"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: String], ["language": "ar"])
        try Data("{\"language\":\"unknown\"}".utf8).write(to: directory.appendingPathComponent("language.json"))
        XCTAssertEqual(try store.load(), .system)
    }

    func testSystemResolverNormalizesRegionsScriptsAndFallsBack() {
        let cases = ["en-US": "en", "ru-RU": "ru", "kk-KZ": "kk", "pt-PT": "pt", "pt_BR": "pt", "es-MX": "es", "fr-CA": "fr", "de-DE": "de", "zh-Hans-CN": "zh", "zh-Hant-TW": "zh", "hi-IN": "hi", "ar-SA": "ar"]
        for (input, expected) in cases {
            XCTAssertEqual(AppLanguage.resolve(selection: .system, preferredLanguages: [input]), AppLanguage(rawValue: expected), input)
        }
        XCTAssertEqual(AppLanguage.resolve(selection: .system, preferredLanguages: ["ja-JP", "fr-FR"]), .fr)
        XCTAssertEqual(AppLanguage.resolve(selection: .system, preferredLanguages: ["ja", "it"]), .en)
        XCTAssertEqual(AppLanguage.resolve(selection: .system, preferredLanguages: []), .en)
        XCTAssertEqual(AppLanguage.resolve(selection: .ar, preferredLanguages: ["en"]), .ar)
        XCTAssertTrue(AppLanguage.ar.isRightToLeft)
        XCTAssertFalse(AppLanguage.en.isRightToLeft)
    }
}
