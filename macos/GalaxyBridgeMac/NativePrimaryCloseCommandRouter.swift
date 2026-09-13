import AppKit
import Combine
import Foundation
import OSLog

/// Keeps the generated SwiftUI File > Close command native while routing it
/// to a frontmost presenter-owned borderless mirror. SwiftUI's WindowGroup
/// command target can otherwise retain the document window that created the
/// mirror and close that window behind it.
@MainActor
final class NativePrimaryCloseCommandRouter: NSObject, ObservableObject, NSMenuItemValidation {
    enum BindingState: Equatable {
        case bound(ObjectIdentifier)
        case missing
        case ambiguous(Int)
    }

    private static let closeAction = #selector(NSWindow.performClose(_:))
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.galaxybridge.mac",
        category: "NativePrimaryCloseCommand"
    )

    private weak var primaryWindowSource: (any NativeCloseAllPrimaryWindowSource)?
    private let application: NSApplication
    private let notificationCenter: NotificationCenter
    private weak var boundItem: NSMenuItem?
    private var originalTarget: AnyObject?
    private var isInstalled = false
    private var isDispatching = false
    private var reconciliationScheduled = false
    private(set) var bindingState: BindingState = .missing

    init(
        primaryWindowSource: any NativeCloseAllPrimaryWindowSource,
        application: NSApplication? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.primaryWindowSource = primaryWindowSource
        self.application = application ?? .shared
        self.notificationCenter = notificationCenter
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
        }
        reconcile()
    }

    @objc func performClose(_ sender: Any?) {
        guard !isDispatching,
              let item = boundItem,
              item.target === self,
              item.action == Self.closeAction
        else { return }

        if let mirror = frontmostPrimaryWindow(), mirror.styleMask.contains(.closable) {
            mirror.performClose(item)
            return
        }
        if let keyWindow = application.keyWindow,
           keyWindow.styleMask.contains(.closable) {
            keyWindow.performClose(item)
            return
        }
        if let frontmost = application.orderedWindows.first(where: { $0.isVisible }),
           frontmost.styleMask.contains(.closable) {
            frontmost.performClose(item)
            return
        }

        isDispatching = true
        let forwardedTarget = originalTarget
        item.target = forwardedTarget
        defer {
            if targetsAreIdentical(item.target, forwardedTarget) {
                item.target = self
            }
            isDispatching = false
        }
        _ = application.sendAction(Self.closeAction, to: forwardedTarget, from: item)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == Self.closeAction else { return false }
        if let mirror = frontmostPrimaryWindow() {
            return mirror.styleMask.contains(.closable)
        }
        if let keyWindow = application.keyWindow {
            return keyWindow.styleMask.contains(.closable)
        }
        if let frontmost = application.orderedWindows.first(where: { $0.isVisible }) {
            return frontmost.styleMask.contains(.closable)
        }
        return nativeValidation(for: menuItem)
    }

    private func frontmostPrimaryWindow() -> SeamlessMirrorWindow? {
        guard let source = primaryWindowSource else { return nil }
        if let frontmost = application.orderedWindows.first(where: { $0.isVisible }),
           source.ownsPrimaryWindow(frontmost) {
            return frontmost as? SeamlessMirrorWindow
        }
        if let keyWindow = application.keyWindow,
           source.ownsPrimaryWindow(keyWindow) {
            return keyWindow as? SeamlessMirrorWindow
        }
        return nil
    }

    private func reconcile() {
        guard !isDispatching, let mainMenu = application.mainMenu else {
            clearBinding()
            bindingState = .missing
            return
        }
        let matches = closeItems(in: mainMenu)
        guard matches.count == 1 else {
            clearBinding()
            bindingState = matches.isEmpty ? .missing : .ambiguous(matches.count)
            return
        }
        let item = matches[0]
        guard boundItem !== item else { return }
        clearBinding()
        originalTarget = item.target
        boundItem = item
        item.target = self
        bindingState = .bound(ObjectIdentifier(item))
        Self.logger.info("Close menu binding active")
    }

    private func clearBinding() {
        if let item = boundItem, item.target === self {
            item.target = originalTarget
        }
        boundItem = nil
        originalTarget = nil
    }

    private func closeItems(in root: NSMenu) -> [NSMenuItem] {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ menu: NSMenu) -> [NSMenuItem] {
            guard visited.insert(ObjectIdentifier(menu)).inserted else { return [] }
            return menu.items.flatMap { item in
                (item.action == Self.closeAction ? [item] : []) + (item.submenu.map(visit) ?? [])
            }
        }
        return visit(root)
    }

    private func nativeValidation(for item: NSMenuItem) -> Bool {
        let target = originalTarget ?? application.target(
            forAction: Self.closeAction,
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
        guard !isDispatching, !reconciliationScheduled else { return }
        reconciliationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconciliationScheduled = false
            self.reconcile()
        }
    }

    private func targetsAreIdentical(_ lhs: AnyObject?, _ rhs: AnyObject?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs === rhs
        default: false
        }
    }
}
