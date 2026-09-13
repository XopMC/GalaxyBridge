#!/bin/sh
# Process-local language overrides exercise Foundation without changing user defaults.
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-system-languages.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
GB_APP="$GB_TMP/LocaleProbe.app"
mkdir -p "$GB_APP/Contents/MacOS" "$GB_APP/Contents/Resources"
cp "$GB_ROOT/macos/GalaxyBridgeMac/Info.plist" "$GB_APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string LocaleProbe "$GB_APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.xopmc.GalaxyBridge.LocaleProbe "$GB_APP/Contents/Info.plist"
for GB_CATALOG in "$GB_ROOT"/macos/GalaxyBridgeMac/Resources/*.lproj; do
    cp -R "$GB_CATALOG" "$GB_APP/Contents/Resources/"
done
cat > "$GB_TMP/main.swift" <<'SWIFT'
import Foundation
import SwiftUI
import AppKit

@MainActor final class DirectionCapture { var direction: LayoutDirection? }
struct DirectionProbe: View {
    @Environment(\.layoutDirection) private var direction
    let capture: DirectionCapture
    var body: some View {
        capture.direction = direction
        return Color.clear.frame(width: 16, height: 16)
    }
}
@main struct LocaleProbe {
@MainActor static func main() {
let expected = ProcessInfo.processInfo.environment["GB_EXPECTED_LANGUAGE"]!
let expectedText = ProcessInfo.processInfo.environment["GB_EXPECTED_DEVICES"]!
let selected = Bundle.main.preferredLocalizations.first ?? ""
let devices = Bundle.main.localizedString(forKey: "DEVICES", value: nil, table: nil)
guard selected == expected, devices == expectedText else {
    fatalError("Language selection failed: wanted \(expected)/\(expectedText), got \(selected)/\(devices)")
}
let rtl = Locale.Language(identifier: selected).characterDirection == .rightToLeft
guard rtl == ["ar", "he", "fa", "ur"].contains(expected) else {
    fatalError("Unexpected character direction for \(expected)")
}
_ = NSApplication.shared
let chrome = DirectionCapture()
let phone = DirectionCapture()
let host = NSHostingView(rootView:
    HStack {
        DirectionProbe(capture: chrome)
        DirectionProbe(capture: phone).environment(\.layoutDirection, .leftToRight)
    }.applicationLanguageLayout()
)
_ = host.fittingSize
host.layoutSubtreeIfNeeded()
guard chrome.direction == (rtl ? .rightToLeft : .leftToRight), phone.direction == .leftToRight else {
    fatalError("SwiftUI direction failed: chrome=\(String(describing: chrome.direction)), phone=\(String(describing: phone.direction))")
}
print("PASS process language \(expected): \(devices), chrome RTL=\(rtl), phone LTR")
}
}
SWIFT
xcrun swiftc -parse-as-library "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationLanguageLayout.swift" "$GB_TMP/main.swift" -o "$GB_APP/Contents/MacOS/LocaleProbe"
GB_EXPECTED_LANGUAGE=en GB_EXPECTED_DEVICES=Devices "$GB_APP/Contents/MacOS/LocaleProbe" -AppleLanguages '(en)'
GB_EXPECTED_LANGUAGE=ar GB_EXPECTED_DEVICES=الأجهزة "$GB_APP/Contents/MacOS/LocaleProbe" -AppleLanguages '(ar)'
GB_EXPECTED_LANGUAGE=ja GB_EXPECTED_DEVICES=デバイス "$GB_APP/Contents/MacOS/LocaleProbe" -AppleLanguages '(ja)'
# Unsupported-only preferences must not inherit the host's Russian UI language.
GB_EXPECTED_LANGUAGE=en GB_EXPECTED_DEVICES=Devices "$GB_APP/Contents/MacOS/LocaleProbe" -AppleLanguages '(it-IT)'
GB_EXPECTED_LANGUAGE=en GB_EXPECTED_DEVICES=Devices "$GB_APP/Contents/MacOS/LocaleProbe" -AppleLanguages '(uk-UA)'
GB_EXPECTED_LANGUAGE=en GB_EXPECTED_DEVICES=Devices "$GB_APP/Contents/MacOS/LocaleProbe" -AppleLanguages '(he-IL)'
GB_EXPECTED_LANGUAGE=en GB_EXPECTED_DEVICES=Devices "$GB_APP/Contents/MacOS/LocaleProbe" -AppleLanguages '(it-IT, uk-UA)'
GB_EXPECTED_LANGUAGE=ru GB_EXPECTED_DEVICES=Устройства "$GB_APP/Contents/MacOS/LocaleProbe" -AppleLanguages '(it-IT, ru)'
GB_EXPECTED_LANGUAGE=pt GB_EXPECTED_DEVICES=Dispositivos "$GB_APP/Contents/MacOS/LocaleProbe" -AppleLanguages '(pt-PT)'
