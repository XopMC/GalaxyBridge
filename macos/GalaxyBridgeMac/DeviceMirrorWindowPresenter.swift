import AppKit
import SwiftUI

@MainActor
final class DeviceMirrorWindowPresenter: NSObject, ObservableObject, NSWindowDelegate,
    NativeCloseAllPrimaryWindowSource
{
    private var windowsByDeviceID: [String: SeamlessMirrorWindow] = [:]
    private var closeHandlersByWindowID: [ObjectIdentifier: () -> Void] = [:]
    private var leasesByWindowID: [ObjectIdentifier: UUID] = [:]

    func present(device: DeviceRow, model: AppModel) {
        if let window = windowsByDeviceID.values.first(where: {
            guard let lease = leasesByWindowID[ObjectIdentifier($0)] else { return false }
            return model.primaryMirrorDeviceID(for: lease) == device.id
        }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Revocation ends its lease even when the empty window remains open.
        // Re-pairing must acquire a fresh lease instead of reusing that shell.
        if let stale = windowsByDeviceID[device.id] { stale.close() }

        let styleMask = MirrorWindowActivationPolicy.seamlessFocusableStyleMask(from: [])
        let initialContentSize = NSSize(width: 430, height: 930)
        let window = SeamlessMirrorWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = device.name
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        let lease = model.primaryMirrorDidOpen(device)
        window.contentViewController = NSHostingController(
            rootView: PresentedDeviceMirror(lease: lease, model: model)
                .applicationLanguageLayout()
        )
        // NSHostingController may briefly report an empty fitting size while
        // the first decoded frame/device row is resolving. A custom
        // borderless NSWindow must not adopt that transient 0×0 size.
        window.setContentSize(initialContentSize)
        window.center()
        if let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            window.setFrame(
                MirrorWindowGeometry.frameReservingHeader(
                    window.frame,
                    visibleFrame: visibleFrame,
                    headerClearance: 48
                ),
                display: false
            )
        }
        leasesByWindowID[ObjectIdentifier(window)] = lease
        registerPrimaryWindow(
            window,
            forDeviceID: device.id,
            onClose: { [weak model] in model?.primaryMirrorDidClose(lease: lease) }
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak window] in
            guard let window,
                  window.frame.width < 280 || window.frame.height < 280 else { return }
            window.setContentSize(initialContentSize)
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func registerPrimaryWindow(
        _ window: SeamlessMirrorWindow,
        forDeviceID deviceID: String,
        onClose: (() -> Void)? = nil
    ) {
        window.delegate = self
        windowsByDeviceID[deviceID] = window
        if let onClose {
            closeHandlersByWindowID[ObjectIdentifier(window)] = onClose
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        (closedWindow as? SeamlessMirrorWindow)?.retireSeamlessPresentation()
        windowsByDeviceID = windowsByDeviceID.filter { $0.value !== closedWindow }
        leasesByWindowID.removeValue(forKey: ObjectIdentifier(closedWindow))
        closeHandlersByWindowID.removeValue(forKey: ObjectIdentifier(closedWindow))?()
    }

    func closeAllPrimaryWindowsSnapshot() -> [SeamlessMirrorWindow] {
        NativeCloseAllWindowOwnership.snapshot(windowsByDeviceID.values)
    }

    func ownsPrimaryWindow(_ window: NSWindow) -> Bool {
        NativeCloseAllWindowOwnership.owns(window, in: windowsByDeviceID.values)
    }
}
