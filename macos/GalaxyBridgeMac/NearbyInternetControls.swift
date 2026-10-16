#if !GALAXYBRIDGE_APP_STORE
import AppKit
import CoreImage
import SwiftUI

struct NearbyPairingSheet: View {
    @ObservedObject var coordinator: NearbyConnectionCoordinator
    let dismiss: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Text("NEARBY_PAIR").font(.title2.bold())
            if let uri = coordinator.nearbyPairingURI, let image = qr(uri) {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 300, height: 300).accessibilityLabel("PAIRING_QR")
            } else { Image(systemName: "qrcode.viewfinder").font(.system(size: 64)).frame(width: 300, height: 300) }
            Text("PAIRING_HINT").foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("NEARBY_PAIR") { coordinator.beginOfflinePairing() }
                Button("CLOSE", action: dismiss).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 440)
    }
    private func qr(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: .init(scaleX: 6, y: 6)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct NearbyInternetControls: View {
    @EnvironmentObject private var model: AppModel
    let device: DeviceRow
    @State private var confirmHelperRemoval = false
    private var rawID: String { device.id.hasPrefix("device:") ? String(device.id.dropFirst(7)) : device.id }
    private var status: NearbyConnectionStatus { model.nearbyConnection.statuses[rawID] ?? .idle }
    private var internet: InternetSharingPresentation { model.internetSharing.devices[device.id] ?? .init() }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) { nearby; Divider().frame(height: 64); sharing }
            VStack(alignment: .leading, spacing: 12) { nearby; sharing }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .confirmationDialog("INTERNET_REMOVE_HELPER", isPresented: $confirmHelperRemoval) {
            Button("INTERNET_REMOVE_HELPER", role: .destructive) {
                Task { await model.internetSharing.uninstallHelper() }
            }
            Button("CANCEL", role: .cancel) {}
        }
    }
    private var nearby: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("NEARBY_CONNECTION", systemImage: "antenna.radiowaves.left.and.right").font(.caption.bold())
            HStack {
                if status == .connected {
                    Button("NEARBY_STOP") { model.disconnectNearby(deviceID: device.id) }
                } else {
                    Button("NEARBY_CONNECT") { model.connectNearby(deviceID: device.id) }
                        .disabled(isWorking || !model.canRevokePairing(deviceID: device.id))
                }
                if isWorking { ProgressView().controlSize(.small) }
                Text(LocalizedStringKey(statusKey)).font(.caption).foregroundStyle(.secondary)
                if case .failed = status { Text("INTERNET_FAILED").foregroundStyle(.orange).font(.caption) }
            }
            Toggle("NEARBY_AUTO_CONNECT", isOn: Binding(
                get: { model.nearbyAutoConnect(deviceID: device.id) },
                set: { model.setNearbyAutoConnect($0, deviceID: device.id) }))
                .font(.caption).disabled(status != .connected && !model.nearbyAutoConnect(deviceID: device.id))
            Text("NEARBY_NETWORK_HINT").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var sharing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("INTERNET_SHARING", isOn: Binding(
                get: { internet.enabled }, set: { model.setInternetSharing($0, deviceID: device.id) }))
                .toggleStyle(.switch).font(.caption.bold())
                .disabled(model.internetSharing.uninstalling || (!internet.enabled && !model.canShareInternet(deviceID: device.id)))
            HStack {
                Text(LocalizedStringKey(internet.key)).font(.caption).foregroundStyle(.secondary)
                if internet.key == "INTERNET_HELPER_REQUIRED" {
                    Button("INTERNET_INSTALL_HELPER") { model.internetSharing.installHelper() }.font(.caption)
                }
                if internet.key == "INTERNET_READY" {
                    Text(LocalizedStringKey(internet.upstream == "vpn" ? "INTERNET_VPN" :
                        internet.upstream == "wifi" ? "INTERNET_WIFI" : "INTERNET_CELLULAR")).font(.caption)
                }
            }
            if FileManager.default.fileExists(atPath: "/var/run/GalaxyBridgeNetworkHelper.sock") {
                Button("INTERNET_REMOVE_HELPER") { confirmHelperRemoval = true }.font(.caption)
                    .disabled(model.internetSharing.uninstalling)
            }
            if model.internetSharing.uninstalling { ProgressView().controlSize(.small) }
            if let key = model.internetSharing.helperError {
                Text(LocalizedStringKey(key)).font(.caption).foregroundStyle(.orange)
            }
            if internet.enabled {
                Picker("INTERNET_POLICY", selection: Binding(get: { model.internetSharing.selection }, set: { model.internetSharing.selection = $0 })) {
                    Text("INTERNET_AUTOMATIC").tag("automatic")
                    Text("INTERNET_BALANCED").tag("balanced")
                    ForEach(model.devices) { row in Text(row.name).tag(row.id) }
                }.labelsHidden().frame(maxWidth: 260)
            }
        }
    }
    private var statusKey: String {
        switch status {
        case .idle, .failed: ""
        case .discovering: "NEARBY_SEARCHING"
        case .connecting: "INTERNET_WAITING"
        case .authenticating: "NEARBY_AUTHENTICATING"
        case .creatingLink: "NEARBY_CREATING"
        case .joiningNetwork: "NEARBY_JOINING"
        case .verifying: "NEARBY_VERIFYING"
        case .connected: "CONNECTION_CONNECTED"
        }
    }
    private var isWorking: Bool {
        switch status {
        case .connecting, .authenticating, .creatingLink, .joiningNetwork, .verifying: true
        default: false
        }
    }
}
#endif
