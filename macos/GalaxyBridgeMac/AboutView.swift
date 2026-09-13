import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 104, height: 104)
                .accessibilityLabel(Text("ABOUT_ICON_ACCESSIBILITY"))

            VStack(spacing: 6) {
                Text("Galaxy Bridge")
                    .font(.largeTitle.weight(.semibold))
                Text("ABOUT_SUBTITLE")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider()

            VStack(spacing: 7) {
                Text("ABOUT_AUTHOR_LABEL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AboutContent.author)
                    .font(.title3.weight(.medium))
                Text(UserFacingText.formatted("ABOUT_VERSION", AboutContent.version))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Link(destination: AboutContent.githubURL) {
                Label("ABOUT_GITHUB", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(30)
        .frame(width: 410)
    }
}

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("ABOUT_TITLE") {
                openWindow(id: "about")
            }
        }
    }
}
