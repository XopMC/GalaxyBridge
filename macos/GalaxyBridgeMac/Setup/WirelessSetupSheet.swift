#if !GALAXYBRIDGE_APP_STORE
import SwiftUI

struct WirelessSetupSheet: View {
    @StateObject private var coordinator = WirelessSetupCoordinator()
    @State private var code = ""
    @FocusState private var codeFocused: Bool
    let connected: (String) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("WIFI_SETUP_TITLE", systemImage: "wifi").font(.title2.bold())
            Text("WIFI_SETUP_EXPLANATION").foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("WIFI_SETUP_STEP_DEVELOPER")
                    Text("WIFI_SETUP_STEP_WIRELESS")
                    Text("WIFI_SETUP_STEP_CODE")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            phaseContent.frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("CLOSE", action: dismiss).keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .task { coordinator.search() }
        .onDisappear { coordinator.cancel(); code = "" }
        .onChange(of: coordinator.service?.id) { _, _ in code = "" }
        .onChange(of: coordinator.phase) { _, phase in
            codeFocused = phase == .enterCode
            if case let .connected(endpoint) = phase { connected(endpoint) }
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch coordinator.phase {
        case .searching:
            HStack { ProgressView().controlSize(.small); Text("WIFI_SETUP_SEARCHING") }
            Text("WIFI_SETUP_SAME_NETWORK").font(.callout).foregroundStyle(.secondary)
        case .multiplePhones:
            Label("WIFI_SETUP_ONE_PHONE", systemImage: "iphone.gen3.radiowaves.left.and.right")
        case .enterCode:
            HStack {
                SecureField("WIFI_SETUP_CODE", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .focused($codeFocused)
                    .onSubmit(submit)
                    .accessibilityIdentifier("wireless-pairing-code")
                Button("WIFI_SETUP_PAIR", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(WirelessADBPairingCode(code) == nil)
                    .keyboardShortcut(.defaultAction)
            }
        case .pairing, .connecting:
            HStack { ProgressView().controlSize(.small); Text("WIFI_SETUP_CONNECTING") }
        case .connected:
            Label("WIFI_SETUP_CONNECTED", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text("WIFI_SETUP_VERIFY_NEXT").foregroundStyle(.secondary)
        case let .failed(key):
            Label(LocalizedStringKey(key), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            Button("WIFI_SETUP_TRY_AGAIN") { code = ""; coordinator.search() }
        }
    }

    private func submit() {
        let submitted = code
        code = ""
        coordinator.submit(code: submitted)
    }
}
#endif
