import Foundation
import Testing

/// Every text in the string catalogs needs its English version; otherwise
/// English systems would show that one text in German.
struct LocalizationTests {
    private static let catalogs = ["Localizable.xcstrings", "ClaudeRing-InfoPlist.xcstrings"]

    private static func catalog(_ name: String) throws -> [String: Any] {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ClaudeRing/\(name)")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    @Test(arguments: catalogs)
    func `Translates every text into English`(name: String) throws {
        let catalog = try Self.catalog(name)
        #expect(catalog["sourceLanguage"] as? String == "de")
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(!strings.isEmpty)

        let untranslated = strings.compactMap { key, value -> String? in
            let entry = value as? [String: Any]
            if entry?["shouldTranslate"] as? Bool == false { return nil }
            let english = ((entry?["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let isTranslated = english?["state"] as? String == "translated" && !(english?["value"] as? String ?? "").isEmpty
            return isTranslated ? nil : key
        }
        #expect(untranslated.isEmpty, "Without English text: \(untranslated.sorted())")
    }
}
