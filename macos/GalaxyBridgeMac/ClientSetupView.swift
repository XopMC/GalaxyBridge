import SwiftUI

/// A phone's feature policy is usable without running the optional diagnostic tests.
struct ClientSetupView: View {
    @ObservedObject var setup: ClientSetupModel
    let deviceID: String
    let deviceName: String
    let connectionReady: Bool
    let pair: () -> Void
    let test: (ClientSetupFeature) -> Void
    let dismiss: () -> Void
    var optionalFeatures: [ClientSetupFeature] = []
    var onSelectionChanged: ((Set<ClientSetupFeature>) -> Void)? = nil
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DEVICE_FEATURES_TITLE").font(.title2.bold())
                    Text(deviceName).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("DONE", action: dismiss).keyboardShortcut(.defaultAction)
            }
            Text("DEVICE_FEATURES_BODY").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(features) { feature in
                        HStack(spacing: 12) {
                            Image(systemName: feature.symbol)
                                .frame(width: 24)
                                .foregroundStyle(.secondary)
                            Text(LocalizedStringKey(feature.titleKey)).font(.body)
                            Spacer(minLength: 12)
                            Toggle(LocalizedStringKey(feature.titleKey), isOn: Binding(get: { setup.isEnabled(feature, deviceID: deviceID) }, set: { enabled in
                            var selected = setup.selection(deviceID: deviceID)
                            if enabled { selected.insert(feature) } else { selected.remove(feature) }
                            if let onSelectionChanged { onSelectionChanged(selected) }
                            else {
                                do { try setup.saveSelection(deviceID: deviceID, features: selected); saveFailed = false }
                                catch { saveFailed = true }
                            }
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(!ClientSetupModel.isVerifiedDeviceID(deviceID))
                        }
                        .padding(.vertical, 9)
                        if feature != features.last { Divider() }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 5)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusSymbol).foregroundStyle(.secondary)
                Text(LocalizedStringKey(statusKey)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if saveFailed { Text("CLIENT_SETUP_SAVE_FAILED").font(.caption).foregroundStyle(.red) }
            if !ClientSetupModel.isVerifiedDeviceID(deviceID) {
                Button("PAIR_DEVICE", action: pair).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 460, height: 600)
    }
    private var features: [ClientSetupFeature] { ClientSetupFeature.shippingFeatures + optionalFeatures.filter { !ClientSetupFeature.shippingFeatures.contains($0) && $0 == .calls } }
    private var statusKey: String {
        if !connectionReady { return "DEVICE_FEATURES_PENDING" }
        switch setup.synchronization(deviceID: deviceID) {
        case .pending: return "DEVICE_FEATURES_APPLYING"
        case .acknowledged: return "DEVICE_FEATURES_APPLIED"
        case .localOnly: return "DEVICE_FEATURES_UPDATE_PHONE"
        case .failed: return "DEVICE_FEATURES_FAILED"
        }
    }
    private var statusSymbol: String {
        setup.synchronization(deviceID: deviceID) == .acknowledged && connectionReady ? "checkmark.circle" : "info.circle"
    }
}
