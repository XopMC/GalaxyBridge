import SwiftUI

@main
struct GalaxyBridgeMacApp: App {
    @NSApplicationDelegateAdaptor(GalaxyBridgeApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var mirrorWindows = DeviceMirrorWindowPresenter()
    @StateObject private var applicationWindows = ApplicationWindowCoordinator()
    @StateObject private var closeRouter: NativePrimaryCloseCommandRouter
    @StateObject private var closeAllRouter: NativeCloseAllCommandRouter

    init() {
        let mirrorWindows = DeviceMirrorWindowPresenter()
        _mirrorWindows = StateObject(wrappedValue: mirrorWindows)
        _closeRouter = StateObject(
            wrappedValue: NativePrimaryCloseCommandRouter(primaryWindowSource: mirrorWindows)
        )
        _closeAllRouter = StateObject(
            wrappedValue: NativeCloseAllCommandRouter(primaryWindowSource: mirrorWindows)
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .applicationLanguageLayout()
                .environmentObject(model)
                .environmentObject(mirrorWindows)
                .environmentObject(applicationWindows)
                .onAppear {
                    closeRouter.install()
                    closeAllRouter.install()
                    // The application delegate owns this closure until AppKit
                    // finishes termination. Keep both coordinators alive for
                    // that same interval so device processes cannot outlive a
                    // SwiftUI state-object teardown.
                    appDelegate.installCleanupHandler { [model, applicationWindows] in
                        await applicationWindows.shutdownForApplicationTermination()
                        await model.shutdownForApplicationTermination()
                    }
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .commands {
            AboutCommands()
            CommandMenu("RECORD_SCREEN") {
                ForEach(model.activeRecordings) { recording in
                    Button(UserFacingText.formatted("STOP_RECORDING_DEVICE", recording.deviceName)) {
                        model.stopRecording(id: recording.id)
                    }
                }
                if !model.activeRecordings.isEmpty && !model.devices.isEmpty { Divider() }
                ForEach(model.devices) { device in
                    Button(device.name) {
                        // Menu state can change before AppKit invokes the action.
                        // A stale Start command must never toggle another recording off.
                        guard model.canStartRecording(deviceID: device.id) else { return }
                        model.toggleRecording(deviceID: device.id)
                    }
                    .disabled(!model.canStartRecording(deviceID: device.id))
                }
            }
        }

        Window("ABOUT_TITLE", id: "about") {
            AboutView()
                .applicationLanguageLayout()
        }
        .windowResizability(.contentSize)

        MenuBarExtra("GalaxyBridge", systemImage: "iphone.and.arrow.forward") {
            Group {
                if !model.activeRecordings.isEmpty {
                    Section("ACTIVE_RECORDINGS") {
                        ForEach(model.activeRecordings) { recording in
                            Button {
                                model.stopRecording(id: recording.id)
                            } label: {
                                Label(
                                    UserFacingText.formatted("STOP_RECORDING_DEVICE", recording.deviceName),
                                    systemImage: "stop.circle.fill"
                                )
                            }
                        }
                    }
                    Divider()
                }
                if model.devices.isEmpty {
                    Text("NO_DEVICE")
                } else {
                    ForEach(model.devices) { device in
                        Text(device.name)
                    }
                }
                Divider()
                Button("REFRESH", action: model.refresh)
                Button("QUIT") { NSApplication.shared.terminate(nil) }
            }
            .applicationLanguageLayout()
        }
    }
}
