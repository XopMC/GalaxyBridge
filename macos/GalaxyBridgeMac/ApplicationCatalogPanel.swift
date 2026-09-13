import AppKit
import SwiftUI

struct ApplicationCatalogPanel: View {
    let device: DeviceRow
    @EnvironmentObject private var model: AppModel
#if !GALAXYBRIDGE_APP_STORE
    @EnvironmentObject private var applicationWindows: ApplicationWindowCoordinator
#endif
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("APPLICATIONS_TITLE").font(.title2.bold())
                    Text("APPLICATIONS_SUBTITLE").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.loadApplicationCatalog(deviceID: device.id, force: true)
                } label: {
                    Label("APPLICATIONS_REFRESH", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            switch state {
            case .idle, .loading:
                ContentUnavailableView {
                    Label("APPLICATIONS_LOADING", systemImage: "square.grid.3x3.fill")
                } description: {
                    Text("APPLICATIONS_LOADING_HINT")
                } actions: {
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .available(items):
                if items.isEmpty {
                    ContentUnavailableView(
                        "APPLICATIONS_EMPTY",
                        systemImage: "square.grid.3x3",
                        description: Text("APPLICATIONS_EMPTY_HINT")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextField("APPLICATIONS_SEARCH", text: $search)
                        .textFieldStyle(.roundedBorder)
                    let matches = filtered(items)
                    if matches.isEmpty {
                        ContentUnavailableView(
                            "APPLICATIONS_EMPTY",
                            systemImage: "magnifyingglass",
                            description: Text("APPLICATIONS_SEARCH_EMPTY_HINT")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 118, maximum: 150), spacing: 16)],
                                spacing: 18
                            ) {
                                ForEach(matches) { application in
                                    applicationButton(application)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            case let .unavailable(reason):
                unavailable(reason)
            case .failed:
                ContentUnavailableView {
                    Label("APPLICATIONS_FAILED", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                } description: {
                    Text("APPLICATIONS_FAILED_HINT")
                } actions: {
                    Button("TRY_AGAIN") {
                        model.loadApplicationCatalog(deviceID: device.id, force: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .task(id: ApplicationCatalogLoadKey(deviceID: device.id, adbSerial: device.adbSerial)) {
            model.loadApplicationCatalog(deviceID: device.id)
        }
    }

    private var state: ApplicationCatalogState {
        model.applicationCatalogsByDevice[device.id] ?? .idle
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    private func filtered(_ items: [ApplicationCatalogItem]) -> [ApplicationCatalogItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.packageName.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func applicationButton(_ application: ApplicationCatalogItem) -> some View {
#if GALAXYBRIDGE_APP_STORE
        applicationTile(application)
#else
        Button {
            applicationWindows.present(application: application, device: device, model: model)
        } label: {
            applicationTile(application)
        }
        .buttonStyle(.plain)
        .help(String(localized: "APPLICATION_OPEN_HINT"))
#endif
    }

    private func applicationTile(_ application: ApplicationCatalogItem) -> some View {
        VStack(spacing: 10) {
            ZStack {
                if let data = application.iconPNG, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .fill(.regularMaterial)
                        Image(systemName: "app.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scaledToFit()
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(application.label)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func unavailable(_ reason: ApplicationCatalogUnavailableReason) -> some View {
        let title: LocalizedStringKey = reason == .storeBuildUnsupported
            ? "APPLICATIONS_STORE_UNAVAILABLE"
            : "APPLICATIONS_DIRECT_CONNECTION_REQUIRED"
        let hint: LocalizedStringKey = reason == .storeBuildUnsupported
            ? "APPLICATIONS_STORE_UNAVAILABLE_HINT"
            : "APPLICATIONS_DIRECT_CONNECTION_HINT"
        return ContentUnavailableView(title, systemImage: "square.grid.3x3", description: Text(hint))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
