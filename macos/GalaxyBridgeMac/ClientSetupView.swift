import SwiftUI

struct ClientSetupView: View {
    private enum Step: Int, CaseIterable { case choose, connection, access, verify, finish }
    @ObservedObject var setup: ClientSetupModel
    let deviceID: String
    let deviceName: String
    let connectionReady: Bool
    let pair: () -> Void
    let test: (ClientSetupFeature) -> Void
    let dismiss: () -> Void
    @State private var step: Step = .choose
    @State private var selected: Set<ClientSetupFeature> = []
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("CLIENT_SETUP_TITLE").font(.title2.bold())
                Spacer()
                Text(deviceName).foregroundStyle(.secondary).lineLimit(1)
            }
            ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                .accessibilityLabel(Text(titleKey))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(titleKey).font(.headline)
                    switch step {
                    case .choose:
                        ForEach(ClientSetupFeature.allCases) { feature in
                            Toggle(isOn: Binding(get: { selected.contains(feature) }, set: {
                                if $0 { selected.insert(feature) } else { selected.remove(feature) }
                            })) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(LocalizedStringKey(feature.titleKey), systemImage: feature.symbol)
                                    if !feature.supportsLiveVerification {
                                        Text("CLIENT_SETUP_VERIFICATION_UNAVAILABLE")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            // A saved unavailable choice can still be deselected.
                            // New setup must not lead into an impossible test.
                            .disabled(!feature.supportsLiveVerification && !selected.contains(feature))
                        }
                        if selected.isEmpty { Text("CLIENT_SETUP_CHOOSE_ONE").foregroundStyle(.secondary) }
                        if !ClientSetupModel.isVerifiedDeviceID(deviceID) {
                            Button("PAIR_DEVICE", action: pair).buttonStyle(.borderedProminent)
                        }
                    case .connection:
                        Text("PAIRING_HINT").foregroundStyle(.secondary)
                        if !connectionReady { Button("PAIR_DEVICE", action: pair) }
                    case .access:
                        Text("CLIENT_SETUP_ACCESS_BODY").foregroundStyle(.secondary)
                        ForEach(selectedFeatures) { feature in
                            Label(LocalizedStringKey(feature.titleKey), systemImage: feature.symbol)
                        }
                    case .verify:
                        Text("CLIENT_SETUP_VERIFY_BODY").foregroundStyle(.secondary)
                        Button("CLIENT_SETUP_CHOOSE") { step = .choose }
                        ForEach(selectedFeatures) { feature in verificationRow(feature) }
                    case .finish:
                        ForEach(selectedFeatures) { feature in
                            Label(LocalizedStringKey(feature.titleKey), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text("CLIENT_SETUP_VERIFIED").foregroundStyle(.secondary)
                    }
                    if saveFailed { Text("CLIENT_SETUP_SAVE_FAILED").foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("CLOSE", action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                if step != .choose {
                    Button("BACK") { step = Step(rawValue: step.rawValue - 1)! }
                }
                Button(LocalizedStringKey(step == .finish ? "DONE" : "CLIENT_SETUP_CONTINUE"), action: advance)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
            }
        }
        .padding(24).frame(width: 560, height: 570)
        .onAppear {
            selected = setup.selection(deviceID: deviceID)
            if !selected.isEmpty { step = .verify }
        }
        .onChange(of: connectionReady) { _, ready in
            if !ready { setup.invalidate(deviceID: deviceID); if step == .finish { step = .connection } }
        }
        .onChange(of: setup.allSelectedVerified(deviceID: deviceID)) { _, verified in
            if !verified && step == .finish { step = .verify }
        }
    }
    private var selectedFeatures: [ClientSetupFeature] {
        ClientSetupFeature.allCases.filter { selected.contains($0) }
    }
    private var titleKey: LocalizedStringKey {
        switch step {
        case .choose: "CLIENT_SETUP_CHOOSE"
        case .connection: "PAIR_DEVICE"
        case .access: "CLIENT_SETUP_ACCESS"
        case .verify: "CLIENT_SETUP_VERIFY"
        case .finish: "DONE"
        }
    }
    private var canAdvance: Bool {
        switch step {
        case .choose: !selected.isEmpty && ClientSetupModel.isVerifiedDeviceID(deviceID)
        case .connection: connectionReady
        case .access: true
        case .verify: connectionReady && setup.allSelectedVerified(deviceID: deviceID)
        case .finish: connectionReady && setup.allSelectedVerified(deviceID: deviceID)
        }
    }
    private func advance() {
        if step == .choose {
            do { try setup.saveSelection(deviceID: deviceID, features: selected); saveFailed = false }
            catch { saveFailed = true; return }
        }
        if step == .finish { dismiss() }
        else { step = Step(rawValue: step.rawValue + 1)! }
    }
    private func verificationRow(_ feature: ClientSetupFeature) -> some View {
        let state = setup.verification(deviceID: deviceID, feature: feature)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label(LocalizedStringKey(feature.titleKey), systemImage: feature.symbol)
                Text(LocalizedStringKey(state == .unavailable ? "CLIENT_SETUP_VERIFICATION_UNAVAILABLE" : state == .verified ? "CLIENT_SETUP_VERIFIED" : state == .checking ? "CLIENT_SETUP_CHECKING" : "CLIENT_SETUP_PENDING"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .verified { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            else {
                Button("CLIENT_SETUP_TEST") {
                    guard setup.beginVerification(deviceID: deviceID, feature: feature) != nil else { return }
                    test(feature)
                }.disabled(!connectionReady || state == .unavailable)
            }
        }
    }
}
