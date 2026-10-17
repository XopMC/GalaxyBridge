#if !GALAXYBRIDGE_APP_STORE
import SwiftUI

/// Discovery supplies a route only; the phone must explicitly approve first trust.
struct NearbyDiscoveryView: View {
    let suggestions: [NearbyDiscoverySuggestion]
    let onAdd: (NearbyDiscoverySuggestion) -> Void
    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("DISCOVERY_NEARBY_TITLE", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Text("DISCOVERY_UNTRUSTED_HINT").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(suggestions) { suggestion in
                    HStack(spacing: 12) {
                        Image(systemName: "smartphone").foregroundStyle(.secondary)
                        if let model = suggestion.model { Text(verbatim: model) }
                        else { Text("DISCOVERY_GENERIC_PHONE") }
                        Spacer(minLength: 12)
                        Button("DISCOVERY_ADD_PHONE") { onAdd(suggestion) }
                    }.padding(.vertical, 4)
                }
            }.padding(16)
        }
    }
}
#endif
