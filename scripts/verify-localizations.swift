#!/usr/bin/env swift
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// This checks the user-selected shipping catalogs and deliberate English fallback.
// Structural validation does not replace visual or linguistic review.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

func matches(_ pattern: String, _ text: String, group: Int = 0) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    let source = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
        source.substring(with: $0.range(at: group))
    }
}

func placeholders(_ value: String) -> [String] {
    // Argument order matters unless a translation explicitly uses positions.
    let specs = matches(#"%(?:[0-9]+\$)?[-+ #0]*(?:[0-9]+|\*)?(?:\.[0-9]+)?(?:hh|ll|[hlLzjt])?[@a-zA-Z%]"#, value)
        .filter { $0 != "%%" }
    var explicit = 0
    let result = specs.enumerated().map { index, spec -> String in
        if let dollar = spec.firstIndex(of: "$"), let position = Int(spec.dropFirst().prefix(while: \.isNumber)) {
            explicit += 1
            return "\(position):\(spec[spec.index(after: dollar)...])"
        }
        return "\(index + 1):\(spec.dropFirst())"
    }.sorted()
    return explicit != 0 && explicit != specs.count ? result + ["INVALID_MIXED_POSITIONS"] : result
}

func validate(_ values: [String: String], reference: [String: String], label: String) {
    for (key, value) in reference {
        check(!placeholders(value).contains("INVALID_MIXED_POSITIONS"), "\(label): invalid reference format in \(key)")
    }
    let missing = Set(reference.keys).subtracting(values.keys).sorted()
    let extra = Set(values.keys).subtracting(reference.keys).sorted()
    check(missing.isEmpty, "\(label): missing \(missing.joined(separator: ", "))")
    check(extra.isEmpty, "\(label): unknown \(extra.joined(separator: ", "))")
    for (key, value) in values {
        check(!placeholders(value).contains("INVALID_MIXED_POSITIONS"), "\(label): invalid translation format in \(key)")
        check(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(label): empty \(key)")
        if let original = reference[key] {
            check(placeholders(value) == placeholders(original), "\(label): incompatible placeholders in \(key)")
        }
    }
}

func validateUnchanged(_ values: [String: String], reference: [String: String], allowed: [String: String], label: String) {
    let unchanged = values.filter { reference[$0.key] == $0.value }
    check(unchanged == allowed, "\(label): English-identical terms differ from reviewed terminology allowlist")
}

func strings(_ url: URL) throws -> [String: String] {
    let data = try Data(contentsOf: url)
    let text = String(decoding: data, as: UTF8.self)
    let keys = matches(#"^\s*\"([^\"]+)\"\s*="#, text, group: 1)
    check(Set(keys).count == keys.count, "\(url.path): duplicate keys")
    guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else {
        throw NSError(domain: "Invalid strings catalog", code: 1)
    }
    return dictionary
}

final class AndroidStrings: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    var duplicate = false
    private var key: String?
    private var value = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if elementName == "string" {
            key = attributes["name"]
            value = ""
            if let key, values[key] != nil { duplicate = true }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if key != nil { value += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "string", let key { values[key] = value; self.key = nil }
    }
}

func androidStrings(_ url: URL) throws -> [String: String] {
    let delegate = AndroidStrings()
    let parser = XMLParser(data: try Data(contentsOf: url))
    parser.delegate = delegate
    guard parser.parse() else { throw parser.parserError! }
    check(!delegate.duplicate, "\(url.path): duplicate keys")
    return delegate.values
}

if CommandLine.arguments.dropFirst().contains("--self-test") {
    let reference = ["TITLE": "Screen", "DETAIL": "%d: %@"]
    func rejects(_ candidate: [String: String], _ label: String) {
        failures = []
        validate(candidate, reference: reference, label: label)
        guard !failures.isEmpty else { fatalError("Verifier accepted \(label)") }
    }
    rejects(["TITLE": "Экран"], "missing key")
    rejects(["TITLE": "Экран", "DETAIL": "%d: %@", "EXTRA": "test"], "unknown key")
    rejects(["TITLE": " ", "DETAIL": "%d: %@"], "empty translation")
    rejects(["TITLE": "Экран", "DETAIL": "%@: %d"], "unindexed argument reordering")
    rejects(["TITLE": "Экран", "DETAIL": "%d: %d"], "wrong argument type")
    rejects(["TITLE": "Экран", "DETAIL": "%2$@: %d"], "mixed argument positions")
    failures = []
    let malformed = ["DETAIL": "%1$d: %@"]
    validate(malformed, reference: malformed, label: "invalid identical catalogs")
    guard !failures.isEmpty else { fatalError("Verifier accepted an invalid reference format") }
    failures = []
    validate(["TITLE": "Экран", "DETAIL": "%2$@: %1$d"], reference: reference, label: "valid positioned translation")
    check(placeholders("100%%") == [], "literal percent is not an argument")
    validateUnchanged(["SMS": "SMS"], reference: ["SMS": "SMS"], allowed: ["SMS": "SMS"], label: "allowed acronym")
    guard failures.isEmpty else { fatalError(failures.joined(separator: "; ")) }
    validateUnchanged(["TITLE": "Screen"], reference: ["TITLE": "Screen"], allowed: [:], label: "disguised fallback")
    guard !failures.isEmpty else { fatalError("Verifier accepted untranslated English") }
    failures = []
    let xml = XMLParser(data: Data("<resources><string name=\"a\">One</string><string name=\"a\">Two</string></resources>".utf8))
    let delegate = AndroidStrings()
    xml.delegate = delegate
    check(xml.parse() && delegate.duplicate, "duplicate Android key was not detected")
    guard failures.isEmpty else { fatalError(failures.joined(separator: "; ")) }
    print("PASS localization verifier: missing/extra/empty keys, positional formats and duplicate XML keys")
    exit(0)
}

struct LanguageManifest: Decodable {
    struct Entry: Decodable { let id: String; let macOS: String; let android: String }
    let locales: [Entry]
    let fallbackLanguage: String
    let shippingScope: String
    let languageCount: Int
}
let manifest = try JSONDecoder().decode(LanguageManifest.self, from: Data(contentsOf:
    root.appendingPathComponent("docs/localization/system-languages.json")))
let approved = Set(["en", "ru", "de", "fr", "es", "pt", "ar", "zh-Hans", "zh-Hant", "ja", "ko"])
check(Set(manifest.locales.map(\.id)).count == manifest.locales.count, "duplicate shipping-language entries")
check(Set(manifest.locales.map(\.id)) == approved, "shipping languages differ from the explicit 2026-09-13 user scope")
check(manifest.languageCount == 10 && manifest.locales.count == 11, "expected ten languages and eleven catalogs")
check(manifest.fallbackLanguage == "en", "unsupported language fallback must be English")
check(manifest.shippingScope == "user-selected-popular-languages", "obsolete all-system-language shipping scope")
let unchangedTerms = try JSONDecoder().decode([String: [String: [String: String]]].self, from: Data(contentsOf:
    root.appendingPathComponent("docs/localization/unchanged-terms.json")))
let manager = FileManager.default
let macResources = root.appendingPathComponent("macos/GalaxyBridgeMac/Resources")
let macDirectories = try manager.contentsOfDirectory(at: macResources, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "lproj" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
let macReference = try strings(macResources.appendingPathComponent("en.lproj/Localizable.strings"))
let infoReference = try strings(macResources.appendingPathComponent("en.lproj/InfoPlist.strings"))
for directory in macDirectories {
    let values = try strings(directory.appendingPathComponent("Localizable.strings"))
    validate(values, reference: macReference, label: directory.lastPathComponent)
    if directory.lastPathComponent != "en.lproj" {
        validateUnchanged(values, reference: macReference,
            allowed: unchangedTerms["macOS"]?[directory.deletingPathExtension().lastPathComponent] ?? [:], label: directory.lastPathComponent)
    }
    try validate(strings(directory.appendingPathComponent("InfoPlist.strings")), reference: infoReference, label: "\(directory.lastPathComponent)/InfoPlist")
}
let infoURL = root.appendingPathComponent("macos/GalaxyBridgeMac/Info.plist")
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), options: [], format: nil) as! [String: Any]
let declared = Set(info["CFBundleLocalizations"] as? [String] ?? [])
let shipped = Set(macDirectories.map { $0.deletingPathExtension().lastPathComponent })
check(info["CFBundleDevelopmentRegion"] as? String == "en", "macOS development fallback must be English")
let packageSource = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
check(packageSource.contains("defaultLocalization: \"en\""), "SwiftPM resource bundle fallback must be English")
check(macReference["DEVICES"] == "Devices", "macOS English reference was replaced by another language")
check(Set(unchangedTerms["macOS"]?.keys.map { $0 } ?? []) == shipped.subtracting(["en"]),
      "terminology allowlist must contain only shipped translated Mac catalogs")
for preferences in [["it-IT"], ["uk-UA"], ["he-IL"], ["fa-IR"], ["zz-ZZ"], ["it-IT", "uk-UA"]] {
    check(Bundle.preferredLocalizations(from: shipped.sorted(), forPreferences: preferences).first == "en",
          "unsupported-only preferences must select English: \(preferences)")
}
check(Bundle.preferredLocalizations(from: shipped.sorted(), forPreferences: ["pt-PT"]).first == "pt",
      "Portuguese regions must use the shared pt catalog")
check(declared == shipped, "macOS declared localizations differ from shipped catalogs")
check(shipped == Set(manifest.locales.map(\.id)), "macOS catalogs differ from shipping-language matrix")

let androidResources = root.appendingPathComponent("android/app/src/main/res")
let androidReference = try androidStrings(androidResources.appendingPathComponent("values/strings.xml"))
check(androidReference["action_continue"] == "Continue" && androidReference["identity_title"] == "Connect your Mac",
      "Android unqualified fallback resources must remain English")
check(Set(unchangedTerms["android"]?.keys.map { $0 } ?? []) == Set(manifest.locales.map(\.android)).subtracting(["values"]),
      "terminology allowlist must contain only shipped translated Android catalogs")
let androidDirectories = try manager.contentsOfDirectory(at: androidResources, includingPropertiesForKeys: nil)
    .filter { $0.lastPathComponent == "values" || $0.lastPathComponent.hasPrefix("values-") }
    .filter { manager.fileExists(atPath: $0.appendingPathComponent("strings.xml").path) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
for directory in androidDirectories {
    let values = try androidStrings(directory.appendingPathComponent("strings.xml"))
    validate(values, reference: androidReference, label: directory.lastPathComponent)
    if directory.lastPathComponent != "values" {
        validateUnchanged(values, reference: androidReference,
            allowed: unchangedTerms["android"]?[directory.lastPathComponent] ?? [:], label: directory.lastPathComponent)
    }
}

check(Set(androidDirectories.map(\.lastPathComponent)) == Set(manifest.locales.map(\.android)),
      "Android catalogs differ from shipping-language matrix")
let localeConfig = try String(contentsOf: androidResources.appendingPathComponent("xml/locales_config.xml"), encoding: .utf8)
let configured = Set(matches(#"android:name=\"([^\"]+)\""#, localeConfig, group: 1))
check(configured == Set(manifest.locales.map(\.id)), "Android per-app languages differ from shipping-language matrix")
let androidManifest = try String(contentsOf: root.appendingPathComponent("android/app/src/main/AndroidManifest.xml"), encoding: .utf8)
check(androidManifest.contains("android:localeConfig=\"@xml/locales_config\""), "Android locale config is not wired")
check(androidManifest.contains("android:supportsRtl=\"true\""), "Android RTL support is disabled")
// Reject a catalog consisting mostly of English fallback disguised as translation.
for directory in macDirectories where directory.lastPathComponent != "en.lproj" {
    let values = try strings(directory.appendingPathComponent("Localizable.strings"))
    let unchanged = values.filter { macReference[$0.key] == $0.value }.count
    check(unchanged * 2 < macReference.count, "\(directory.lastPathComponent): majority untranslated English")
    for (key, value) in values {
        check(!value.contains("GBTOKEN"), "\(directory.lastPathComponent): unreplaced translation token in \(key)")
    }
}

// Catch constant resource-key lookups in the UI, not arbitrary protocol tokens.
let swiftRoot = root.appendingPathComponent("macos/GalaxyBridgeMac")
let swiftFiles = manager.enumerator(at: swiftRoot, includingPropertiesForKeys: nil)!
let keyPattern = #"(?:(?:Text|Button|Label|Menu|Picker|Toggle|\.help|\.navigationTitle|localized|formatted)\(\s*|String\(localized:\s*)\"([A-Z][A-Z0-9_]+)\""#
for case let url as URL in swiftFiles where url.pathExtension == "swift" {
    let source = try String(contentsOf: url, encoding: .utf8)
    for key in Set(matches(keyPattern, source, group: 1)) {
        check(macReference[key] != nil, "\(url.lastPathComponent): missing UI key \(key)")
    }
}
if !failures.isEmpty {
    fputs("FAIL localization catalogs:\n" + failures.joined(separator: "\n") + "\n", stderr)
    exit(1)
}
print("PASS macOS \(macReference.count) UI + \(infoReference.count) permission keys: \(shipped.sorted().joined(separator: ", "))")
print("PASS Android \(androidReference.count) keys: \(androidDirectories.map(\.lastPathComponent).joined(separator: ", "))")
print("PASS user-selected shipping matrix: \(manifest.locales.count) catalogs per platform; unsupported languages fall back to English. Linguistic and visual review remain separate.")
