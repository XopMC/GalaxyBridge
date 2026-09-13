import SwiftUI

/// SwiftUI may inherit the host's layout direction even when Bundle selects an
/// app-specific language. Resolve chrome direction from the language we display.
enum ApplicationLanguageLayout {
    static var selectedLanguage: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    static var direction: LayoutDirection {
        direction(for: selectedLanguage)
    }

    static func direction(for language: String) -> LayoutDirection {
        Locale.Language(identifier: language).characterDirection == .rightToLeft
            ? .rightToLeft : .leftToRight
    }
}

extension View {
    func applicationLanguageLayout() -> some View {
        environment(\.layoutDirection, ApplicationLanguageLayout.direction)
    }
}
