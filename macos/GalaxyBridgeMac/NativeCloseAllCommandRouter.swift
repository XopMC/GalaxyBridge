import AppKit
import Combine
import Foundation
import os

@MainActor
protocol NativeCloseAllPrimaryWindowSource: AnyObject {
    func closeAllPrimaryWindowsSnapshot() -> [SeamlessMirrorWindow]
    func ownsPrimaryWindow(_ window: NSWindow) -> Bool
}

@MainActor
enum NativeCloseAllWindowOwnership {
    static func snapshot<S: Sequence>(_ windows: S) -> [SeamlessMirrorWindow]
    where S.Element == SeamlessMirrorWindow {
        var identities: Set<ObjectIdentifier> = []
        return windows.filter { identities.insert(ObjectIdentifier($0)).inserted }
    }

    static func owns<S: Sequence>(_ window: NSWindow, in windows: S) -> Bool
    where S.Element == SeamlessMirrorWindow {
        windows.contains { $0 === window }
    }
}

@MainActor
final class NativeCloseAllCommandRouter: NSObject, ObservableObject, NSMenuItemValidation {
    enum BindingState: Equatable {
        case bound(ObjectIdentifier)
        case missing
        case ambiguous(Int)
    }

    private static let closeAllAction = NSSelectorFromString("closeAll:")
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.galaxybridge.mac",
        category: "NativeCloseAllCommand"
    )

    private weak var primaryWindowSource: (any NativeCloseAllPrimaryWindowSource)?
    private let application: NSApplication
    private let notificationCenter: NotificationCenter
    private let diagnosticHandler: ((BindingState) -> Void)?
    private weak var boundItem: NSMenuItem?
    private var originalTarget: AnyObject?
    private var isInstalled = false
    private var isDispatching = false
    private var reconciliationScheduled = false
    private var needsReconciliationAfterDispatch = false
    private var trackingMenuIDs: Set<ObjectIdentifier> = []
    private var lastReportedState: BindingState?
    private(set) var bindingState: BindingState = .missing

    init(
        primaryWindowSource: any NativeCloseAllPrimaryWindowSource,
        application: NSApplication? = nil,
        notificationCenter: NotificationCenter = .default,
        diagnosticHandler: ((BindingState) -> Void)? = nil
    ) {
        self.primaryWindowSource = primaryWindowSource
        self.application = application ?? .shared
        self.notificationCenter = notificationCenter
        self.diagnosticHandler = diagnosticHandler
        super.init()
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    func install() {
        if !isInstalled {
            isInstalled = true
            for name in [
                NSMenu.didAddItemNotification,
                NSMenu.didRemoveItemNotification,
                NSApplication.didBecomeActiveNotification,
            ] {
                notificationCenter.addObserver(
                    self,
                    selector: #selector(scheduleReconciliation(_:)),
                    name: name,
                    object: nil
                )
            }
            notificationCenter.addObserver(
                self,
                selector: #selector(menuDidBeginTracking(_:)),
                name: NSMenu.didBeginTrackingNotification,
                object: nil
            )
            notificationCenter.addObserver(
                self,
                selector: #selector(menuDidEndTracking(_:)),
                name: NSMenu.didEndTrackingNotification,
                object: nil
            )
        }
        reconcile()
    }

    @objc func closeAll(_ sender: Any?) {
        guard !isDispatching,
              let item = boundItem,
              item.target === self,
              item.action == Self.closeAllAction else { return }

        isDispatching = true
        let source = primaryWindowSource
        let snapshot = NativeCloseAllWindowOwnership.snapshot(
            source?.closeAllPrimaryWindowsSnapshot() ?? []
        )
        Self.logger.info(
            "Close All dispatch admitted: registered primaries \(snapshot.count, privacy: .public)"
        )
        var attemptedWindowIDs: Set<ObjectIdentifier> = []
        let priorObservers = snapshot.map { ($0, $0.closeAttemptObserver) }
        for (window, priorObserver) in priorObservers {
            window.closeAttemptObserver = { attemptedWindow in
                priorObserver?(attemptedWindow)
                attemptedWindowIDs.insert(ObjectIdentifier(attemptedWindow))
            }
        }

        let forwardedTarget = originalTarget
        item.target = forwardedTarget
        defer {
            for (window, observer) in priorObservers {
                window.closeAttemptObserver = observer
            }
            if targetsAreIdentical(item.target, forwardedTarget) {
                item.target = self
            }
            isDispatching = false
            if needsReconciliationAfterDispatch {
                needsReconciliationAfterDispatch = false
                reconcile()
            }
        }

        _ = application.sendAction(Self.closeAllAction, to: forwardedTarget, from: item)

        for window in snapshot {
            let identity = ObjectIdentifier(window)
            if !attemptedWindowIDs.contains(identity),
               source?.ownsPrimaryWindow(window) == true,
               window.styleMask.contains(.closable) {
                window.performClose(item)
            }

            // SwiftUI's stock closeAll: target can synchronously deliver
            // windowWillClose for a presenter-owned borderless window yet
            // leave that non-scene window ordered on screen. Once the
            // presenter has retired ownership, it is not a vetoed window and
            // must not survive as an interactive ghost above other apps.
            if source?.ownsPrimaryWindow(window) == false, window.isVisible {
                window.orderOut(nil)
            }
        }
        settleRetiredPrimaryWindows(snapshot, remainingPasses: 2)
        Self.logger.info(
            "Close All dispatch completed: attempts \(attemptedWindowIDs.count, privacy: .public)"
        )
    }

    private func settleRetiredPrimaryWindows(
        _ windows: [SeamlessMirrorWindow],
        remainingPasses: Int
    ) {
        guard remainingPasses > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for window in windows
            where self.primaryWindowSource?.ownsPrimaryWindow(window) == false && window.isVisible {
                window.orderOut(nil)
            }
            self.settleRetiredPrimaryWindows(windows, remainingPasses: remainingPasses - 1)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == Self.closeAllAction else { return false }
        if let source = primaryWindowSource,
           NativeCloseAllWindowOwnership.snapshot(source.closeAllPrimaryWindowsSnapshot()).contains(where: {
               source.ownsPrimaryWindow($0) && $0.styleMask.contains(.closable)
           }) {
            return true
        }
        return nativeValidation(for: menuItem)
    }

    private func reconcile() {
        if isDispatching {
            needsReconciliationAfterDispatch = true
            return
        }
        guard let mainMenu = application.mainMenu else {
            clearBinding()
            transition(to: .missing)
            return
        }

        let matches = closeAllItems(in: mainMenu)
        guard matches.count == 1 else {
            clearBinding()
            transition(to: matches.isEmpty ? .missing : .ambiguous(matches.count))
            return
        }

        let item = matches[0]
        if boundItem === item {
            return
        }
        clearBinding()
        originalTarget = item.target
        boundItem = item
        item.target = self
        transition(to: .bound(ObjectIdentifier(item)))
    }

    private func clearBinding() {
        if let item = boundItem, item.target === self {
            item.target = originalTarget
        }
        boundItem = nil
        originalTarget = nil
    }

    private func transition(to state: BindingState) {
        guard lastReportedState != state else { return }
        bindingState = state
        lastReportedState = state
        diagnosticHandler?(state)
        switch state {
        case let .bound(identity):
            Self.logger.info("Close All menu binding active: \(String(describing: identity), privacy: .public)")
        case .missing:
            Self.logger.error("Close All menu binding unavailable: selector missing")
        case let .ambiguous(count):
            Self.logger.error("Close All menu binding unavailable: \(count, privacy: .public) selector matches")
        }
    }

    private func closeAllItems(in root: NSMenu) -> [NSMenuItem] {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ menu: NSMenu) -> [NSMenuItem] {
            guard visited.insert(ObjectIdentifier(menu)).inserted else { return [] }
            return menu.items.flatMap { item in
                (item.action == Self.closeAllAction ? [item] : []) + (item.submenu.map(visit) ?? [])
            }
        }
        return visit(root)
    }

    private func nativeValidation(for item: NSMenuItem) -> Bool {
        let target = originalTarget ?? application.target(
            forAction: Self.closeAllAction,
            to: nil,
            from: item
        ) as AnyObject?
        if let menuValidator = target as? NSMenuItemValidation {
            return menuValidator.validateMenuItem(item)
        }
        if let interfaceValidator = target as? NSUserInterfaceValidations {
            return interfaceValidator.validateUserInterfaceItem(item)
        }
        return target != nil
    }

    @objc private func scheduleReconciliation(_ notification: Notification) {
        if isDispatching {
            needsReconciliationAfterDispatch = true
            return
        }
        if !trackingMenuIDs.isEmpty {
            reconcile()
            return
        }
        guard !reconciliationScheduled else { return }
        reconciliationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconciliationScheduled = false
            self.reconcile()
        }
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        if let menu = notification.object as? NSMenu {
            trackingMenuIDs.insert(ObjectIdentifier(menu))
        }
        reconcile()
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        if let menu = notification.object as? NSMenu {
            trackingMenuIDs.remove(ObjectIdentifier(menu))
        } else {
            trackingMenuIDs.removeAll()
        }
        reconcile()
    }

    private func targetsAreIdentical(_ lhs: AnyObject?, _ rhs: AnyObject?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs === rhs
        default: false
        }
    }
}
