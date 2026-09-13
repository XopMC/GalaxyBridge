import AppKit
import Foundation
import SwiftUI

#if TASK5K_PRESENTER_STANDINS
struct DeviceRow {
    let id: String
    let name: String
}

@MainActor
final class AppModel: ObservableObject {
    private var demand = PrimaryScreenDemandRegistry()
    private var created: [UUID] = []
    var liveLeases: Int { created.filter { demand.deviceID(for: $0) != nil }.count }
    func primaryMirrorDidOpen(_ device: DeviceRow) -> UUID {
        let lease = demand.acquire(deviceID: device.id, consumer: .viewer)
        created.append(lease)
        return lease
    }
    func primaryMirrorDidClose(lease: UUID) { demand.release(lease) }
    func primaryMirrorDeviceID(for lease: UUID) -> String? { demand.deviceID(for: lease) }
    func migrate(from oldID: String, to newID: String) { demand.migrate(from: oldID, to: newID) }
    func revoke(_ deviceID: String) { demand.revoke(deviceID) }
}

struct PresentedDeviceMirror: View {
    init(lease: UUID, model: AppModel) {}
    var body: some View { EmptyView() }
}
#endif

@MainActor
private final class NativeCloseAllTestApplication: NSApplication {
    weak var testKeyWindow: NSWindow?

    override var keyWindow: NSWindow? { testKeyWindow ?? super.keyWindow }
    override var mainWindow: NSWindow? { testKeyWindow ?? super.mainWindow }
}

@MainActor
private final class CloseAllTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            do {
                try NativeCloseAllCommandSpec.run()
                print("PASS native SwiftUI-generated Close All routing, forwarding, ownership, veto, and rebinding")
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                Foundation.exit(EXIT_FAILURE)
            }
        }
    }
}

private struct NativeCloseAllTestApp: App {
    @NSApplicationDelegateAdaptor(CloseAllTestDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Native Close All Test") {
            Text("Controlled native menu host").frame(width: 240, height: 120)
        }
    }
}

@main
private enum NativeCloseAllTestBootstrap {
    @MainActor
    static func main() {
        _ = NativeCloseAllTestApplication.shared
        NativeCloseAllTestApp.main()
    }
}

@MainActor
private final class CloseProbe: NSObject, NSWindowDelegate {
    var allowsClose = true
    var onWillClose: (() -> Void)?
    private weak var registryOwner: DeviceMirrorWindowPresenter?
    private(set) var shouldCloseCount = 0
    private(set) var willCloseCount = 0

    init(registryOwner: DeviceMirrorWindowPresenter? = nil) {
        self.registryOwner = registryOwner
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseCount += 1
        return allowsClose
    }

    func windowWillClose(_ notification: Notification) {
        willCloseCount += 1
        onWillClose?()
        registryOwner?.windowWillClose(notification)
    }
}

@MainActor
private final class StockCloseAllProbe: NSResponder, NSMenuItemValidation {
    var onAction: ((Any?) -> Void)?
    var validationResult = true
    private(set) var actionCount = 0
    private(set) var validationCount = 0
    private(set) var lastSender: AnyObject?

    @objc func closeAll(_ sender: Any?) {
        actionCount += 1
        lastSender = sender as AnyObject?
        onAction?(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validationCount += 1
        return validationResult
    }
}

@MainActor
private enum NativeCloseAllCommandSpec {
    private static let closeAllAction = NSSelectorFromString("closeAll:")

    private struct MenuMetadata {
        let title: String
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags
        let action: Selector
    }

    static func run() throws {
        let generatedMenu = try expectValue(NSApp.mainMenu, "SwiftUI must install a main menu")
        let generatedItem = try uniqueCloseAllItem(in: generatedMenu)
        let generatedMetadata = MenuMetadata(
            title: generatedItem.title,
            keyEquivalent: generatedItem.keyEquivalent,
            modifiers: generatedItem.keyEquivalentModifierMask,
            action: try expectValue(generatedItem.action, "generated Close All must have an action")
        )

#if TASK5K_RED
        try demonstrateMissingOwnedPrimaryAugmentation(item: generatedItem)
#else
        try presenterRegistrationOwnsRealCloseObservation()
#if TASK5K_PRESENTER_STANDINS
        try verifiedMigrationAndRevocationKeepExactWindowLease()
#endif
        try twoPrimariesAndStockApplicationControl(menu: generatedMenu, item: generatedItem)
        try stockReorderedClosedPrimaryIsNotLeftVisible(menu: generatedMenu, item: generatedItem)
        try stockVetoIsNotAttemptedTwice(menu: generatedMenu, item: generatedItem)
        try nativeValidationFallsBackWithoutEligiblePrimary(menu: generatedMenu, item: generatedItem)
        try minimizedPrimaryClosesAndReopenIsFresh(menu: generatedMenu, item: generatedItem)
        try accessoriesAreOnlyClosedThroughTheirParent(menu: generatedMenu, item: generatedItem)
        try nativeCloseItemAndFirstResponderRouteStayUntouched(menu: generatedMenu, item: generatedItem)
        try menuReplacementFailureRecoveryAndIdempotence(
            generatedMenu: generatedMenu,
            generatedItem: generatedItem,
            metadata: generatedMetadata
        )
        try lifecycleChangeDuringDispatchIsDeferred(
            generatedMenu: generatedMenu,
            generatedItem: generatedItem,
            metadata: generatedMetadata
        )
        try productionItemBindingAndForwarding(item: generatedItem)
#endif
    }

    private static func demonstrateMissingOwnedPrimaryAugmentation(item: NSMenuItem) throws {
        let source = DeviceMirrorWindowPresenter()
        let primary = makeRegisteredMirror(deviceID: "fold", source: source)
        defer { tearDown(primary.window) }

        try expect(source.ownsPrimaryWindow(primary.window), "the RED primary must be genuinely owned by the production presenter registry")
        let dispatched = NSApp.sendAction(item.action!, to: item.target, from: item)
        try expect(dispatched, "the generated closeAll: item must dispatch through its native route")
        try expectEqual(primary.probe.willCloseCount, 1, "Close All must augment the stock route with the presenter-owned primary")
    }

#if !TASK5K_RED
#if TASK5K_PRESENTER_STANDINS
    private static func verifiedMigrationAndRevocationKeepExactWindowLease() throws {
        let source = DeviceMirrorWindowPresenter()
        let model = AppModel()
        source.present(device: DeviceRow(id: "adb:A", name: "Test Galaxy"), model: model)
        let first = try expectValue(source.closeAllPrimaryWindowsSnapshot().first, "first viewer exists")
        defer { for window in source.closeAllPrimaryWindowsSnapshot() { tearDown(window) } }
        try expectEqual(model.liveLeases, 1, "one real window owns one lease")
        model.migrate(from: "adb:A", to: "device:A")
        source.present(device: DeviceRow(id: "device:A", name: "Test Galaxy"), model: model)
        try expectEqual(source.closeAllPrimaryWindowsSnapshot().count, 1, "verified migration reuses existing window")
        try expectEqual(model.liveLeases, 1, "migration must not acquire a duplicate")
        first.close()
        try expectEqual(model.liveLeases, 0, "old-window close releases canonical lease")
        source.present(device: DeviceRow(id: "device:A", name: "Test Galaxy"), model: model)
        let revoked = try expectValue(source.closeAllPrimaryWindowsSnapshot().first, "new viewer exists")
        model.revoke("device:A")
        source.present(device: DeviceRow(id: "device:A", name: "Test Galaxy"), model: model)
        let repaired = try expectValue(source.closeAllPrimaryWindowsSnapshot().first, "repaired viewer exists")
        try expect(repaired !== revoked, "revoked shell must not be reused without fresh demand")
        try expectEqual(model.liveLeases, 1, "re-pair creates exactly one valid lease")
        repaired.close()
        try expectEqual(model.liveLeases, 0, "replacement close releases its exact lease")
    }
#endif

    private static func presenterRegistrationOwnsRealCloseObservation() throws {
        let source = DeviceMirrorWindowPresenter()
        let primary = makeMirrorWindow()
        defer { tearDown(primary) }
        var releaseCount = 0

        source.registerPrimaryWindow(
            primary,
            forDeviceID: "direct-presenter",
            onClose: { releaseCount += 1 }
        )
        try expect(primary.delegate === source, "production registration must install the presenter as close observer")
        try expect(source.ownsPrimaryWindow(primary), "production registration must add the primary to the actual registry")
        primary.performClose(nil)
        try expect(!source.ownsPrimaryWindow(primary), "the presenter's real close notification must remove the registry entry")
        try expect(primary.isPresentationRetired,
                   "the presenter must retire the seamless presentation before stale SwiftUI updates can reorder it")
        try expectEqual(releaseCount, 1, "a native close must release primary capture demand exactly once")
        source.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: primary))
        try expectEqual(releaseCount, 1, "a duplicate close notification must not release capture demand twice")
    }

    private static func productionItemBindingAndForwarding(item: NSMenuItem) throws {
        let source = DeviceMirrorWindowPresenter()
        let primary = makeRegisteredMirror(deviceID: "fold", source: source)
        let title = item.title
        let keyEquivalent = item.keyEquivalent
        let modifiers = item.keyEquivalentModifierMask
        let action = item.action
        let originalTarget = item.target
        var diagnostics: [NativeCloseAllCommandRouter.BindingState] = []
        let router = NativeCloseAllCommandRouter(
            primaryWindowSource: source,
            notificationCenter: NotificationCenter(),
            diagnosticHandler: { diagnostics.append($0) }
        )
        defer { tearDown(primary.window) }

        router.install()
        router.install()
        try expect(item.target === router, "the exact generated closeAll: item must bind to the router")
        try expectEqual(item.title, title, "binding must preserve the generated title")
        try expectEqual(item.keyEquivalent, keyEquivalent, "binding must preserve the generated key equivalent")
        try expectEqual(item.keyEquivalentModifierMask, modifiers, "binding must preserve key modifiers")
        try expectEqual(item.action, action, "binding must preserve the generated selector")
        try expectEqual(diagnostics.count, 1, "idempotent install must emit one bound transition")

        try expect(NSApp.sendAction(item.action!, to: item.target, from: item), "bound generated Close All must dispatch")
        try expectEqual(primary.probe.shouldCloseCount, 1, "the untouched owned primary must receive one close attempt")
        try expectEqual(primary.probe.willCloseCount, 1, "the untouched owned primary must close once")
        try expect(item.target === router, "the router target must be restored after forwarding")
        try expectEqual(item.title, title, "dispatch must preserve the title")
        try expectEqual(item.keyEquivalent, keyEquivalent, "dispatch must preserve the key equivalent")
        try expectEqual(item.action, action, "dispatch must preserve the action")
        try expect(originalTarget !== router, "the generated production target must not already be the router")
    }

    private static func twoPrimariesAndStockApplicationControl(menu: NSMenu, item: NSMenuItem) throws {
        let originalTarget = item.target
        let source = DeviceMirrorWindowPresenter()
        let primaryA = makeRegisteredMirror(deviceID: "a", source: source)
        let primaryB = makeRegisteredMirror(deviceID: "b", source: source)
        source.registerPrimaryWindow(primaryA.window, forDeviceID: "a-alias")
        primaryA.window.delegate = primaryA.probe
        try expectEqual(source.closeAllPrimaryWindowsSnapshot().count, 2, "the production presenter snapshot identity-deduplicates aliases")
        let application = makeOrdinaryWindow()
        let cleanup = ApplicationCleanupProbe()
        application.delegate = cleanup
        let stock = StockCloseAllProbe()
        stock.onAction = { sender in application.performClose(sender) }
        item.target = stock
        NSApp.mainMenu = menu
        let router = NativeCloseAllCommandRouter(
            primaryWindowSource: source,
            notificationCenter: NotificationCenter()
        )
        defer {
            item.target = originalTarget
            tearDown(primaryA.window)
            tearDown(primaryB.window)
            tearDown(application)
        }

        router.install()
        try expect(NSApp.sendAction(closeAllAction, to: item.target, from: item), "controlled generated Close All must dispatch")
        try expectEqual(stock.actionCount, 1, "the preserved stock target receives exactly one action")
        try expect(stock.lastSender === item, "the preserved stock target receives the production item as sender")
        try expectEqual(primaryA.probe.shouldCloseCount, 1, "primary A receives exactly one performClose")
        try expectEqual(primaryB.probe.shouldCloseCount, 1, "primary B receives exactly one performClose")
        try expectEqual(primaryA.probe.willCloseCount, 1, "primary A closes once")
        try expectEqual(primaryB.probe.willCloseCount, 1, "primary B closes once")
        try expectEqual(cleanup.sessionCloseCount, 1, "stock application cleanup closes its session once")
        try expectEqual(cleanup.leaseReleaseCount, 1, "stock application cleanup releases its lease once")
        try expectEqual(cleanup.recordRemovalCount, 1, "stock application cleanup removes its record once")
    }

    private static func stockReorderedClosedPrimaryIsNotLeftVisible(
        menu: NSMenu,
        item: NSMenuItem
    ) throws {
        let originalTarget = item.target
        let source = DeviceMirrorWindowPresenter()
        let primary = makeRegisteredMirror(deviceID: "ghost", source: source)
        let stock = StockCloseAllProbe()
        item.target = stock
        primary.window.orderFront(nil)
        stock.onAction = { sender in
            primary.window.performClose(sender)
            // Reproduce SwiftUI's installed closeAll: transaction: the close
            // notification retires presenter ownership, but the non-scene
            // borderless window is ordered back on the next run-loop turn.
            DispatchQueue.main.async { primary.window.orderFront(nil) }
        }
        let router = NativeCloseAllCommandRouter(
            primaryWindowSource: source,
            notificationCenter: NotificationCenter()
        )
        defer {
            item.target = originalTarget
            tearDown(primary.window)
        }

        router.install()
        try expect(NSApp.sendAction(closeAllAction, to: item.target, from: item),
                   "installed Close All ghost regression must dispatch")
        try expect(!source.ownsPrimaryWindow(primary.window),
                   "stock close must retire presenter ownership")
        drainMainQueue()
        try expect(!primary.window.isVisible,
                   "a retired primary reordered by the stock transaction must be forced off screen")
    }

    private static func stockVetoIsNotAttemptedTwice(menu: NSMenu, item: NSMenuItem) throws {
        let originalTarget = item.target
        let source = DeviceMirrorWindowPresenter()
        let primaryA = makeRegisteredMirror(deviceID: "a", source: source)
        let primaryB = makeRegisteredMirror(deviceID: "b", source: source)
        primaryA.probe.allowsClose = false
        var priorObserverCount = 0
        primaryA.window.closeAttemptObserver = { _ in priorObserverCount += 1 }
        let stock = StockCloseAllProbe()
        stock.onAction = { sender in primaryA.window.performClose(sender) }
        item.target = stock
        NSApp.mainMenu = menu
        let router = NativeCloseAllCommandRouter(
            primaryWindowSource: source,
            notificationCenter: NotificationCenter()
        )
        defer {
            item.target = originalTarget
            tearDown(primaryA.window)
            tearDown(primaryB.window)
        }

        router.install()
        item.menu?.update()
        try expect(item.isEnabled, "an eligible registered primary keeps Close All enabled")
        try expectEqual(primaryA.probe.shouldCloseCount, 0, "validation must not evaluate A's veto")
        try expectEqual(primaryB.probe.shouldCloseCount, 0, "validation must not evaluate B's veto")

        try expect(NSApp.sendAction(closeAllAction, to: item.target, from: item), "veto scenario must dispatch")
        try expectEqual(stock.actionCount, 1, "stock action forwards once")
        try expectEqual(primaryA.probe.shouldCloseCount, 1, "stock-vetoed A is not augmented a second time")
        try expectEqual(primaryA.probe.willCloseCount, 0, "vetoed A remains registered")
        try expectEqual(primaryB.probe.shouldCloseCount, 1, "untouched B is augmented once")
        try expectEqual(primaryB.probe.willCloseCount, 1, "untouched B closes once")
        try expectEqual(priorObserverCount, 1, "a pre-existing attempt observer remains active during dispatch")

        primaryA.probe.allowsClose = true
        try expect(NSApp.sendAction(closeAllAction, to: item.target, from: item), "a later Close All must dispatch")
        try expectEqual(primaryA.probe.shouldCloseCount, 2, "A receives one additional attempt after lifting its veto")
        try expectEqual(primaryA.probe.willCloseCount, 1, "A then closes once")
        try expectEqual(priorObserverCount, 2, "the prior observer is restored after each dispatch")
    }

    private static func nativeValidationFallsBackWithoutEligiblePrimary(
        menu: NSMenu,
        item: NSMenuItem
    ) throws {
        let source = DeviceMirrorWindowPresenter()
        let stock = StockCloseAllProbe()
        stock.validationResult = false
        let originalTarget = item.target
        item.target = stock
        NSApp.mainMenu = menu
        let router = NativeCloseAllCommandRouter(
            primaryWindowSource: source,
            notificationCenter: NotificationCenter()
        )
        defer { item.target = originalTarget }

        router.install()
        try expect(!router.validateMenuItem(item), "without an eligible primary the native disabled result is preserved")
        stock.validationResult = true
        try expect(router.validateMenuItem(item), "without an eligible primary the native enabled result is preserved")
        try expectEqual(stock.validationCount, 2, "native fallback validation is delegated exactly once per request")
    }

    private static func minimizedPrimaryClosesAndReopenIsFresh(menu: NSMenu, item: NSMenuItem) throws {
        let originalTarget = item.target
        let source = DeviceMirrorWindowPresenter()
        let first = makeRegisteredMirror(deviceID: "fold", source: source)
        first.window.miniaturize(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try expect(first.window.isMiniaturized, "the registered primary must be genuinely miniaturized")
        let stock = StockCloseAllProbe()
        item.target = stock
        NSApp.mainMenu = menu
        let router = NativeCloseAllCommandRouter(
            primaryWindowSource: source,
            notificationCenter: NotificationCenter()
        )
        defer {
            item.target = originalTarget
            tearDown(first.window)
        }

        router.install()
        _ = NSApp.sendAction(closeAllAction, to: item.target, from: item)
        try expectEqual(first.probe.willCloseCount, 1, "a miniaturized registered primary closes")
        try expect(!source.ownsPrimaryWindow(first.window), "the close delegate removes the retired registry entry")

        let reopened = makeRegisteredMirror(deviceID: "fold", source: source)
        defer { tearDown(reopened.window) }
        try expect(reopened.window !== first.window, "re-presenting the device creates a fresh primary")
        _ = NSApp.sendAction(closeAllAction, to: item.target, from: item)
        try expectEqual(first.probe.shouldCloseCount, 1, "the retired primary is never attempted again")
        try expectEqual(reopened.probe.shouldCloseCount, 1, "only the fresh registry entry is attempted")
        try expectEqual(reopened.probe.willCloseCount, 1, "the fresh primary closes once")
    }

    private static func accessoriesAreOnlyClosedThroughTheirParent(menu: NSMenu, item: NSMenuItem) throws {
        let originalTarget = item.target
        let source = DeviceMirrorWindowPresenter()
        let primary = makeRegisteredMirror(deviceID: "fold", source: source)
        let accessories = (0..<5).map { _ in makeAccessoryPanel() }
        let accessoryProbes = accessories.map { panel -> CloseProbe in
            let probe = CloseProbe()
            panel.delegate = probe
            primary.window.addChildWindow(panel, ordered: .above)
            return probe
        }
        primary.probe.onWillClose = {
            for panel in accessories {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }
        let stock = StockCloseAllProbe()
        item.target = stock
        NSApp.mainMenu = menu
        let router = NativeCloseAllCommandRouter(
            primaryWindowSource: source,
            notificationCenter: NotificationCenter()
        )
        defer {
            item.target = originalTarget
            tearDown(primary.window)
            accessories.forEach(tearDown)
        }

        router.install()
        _ = NSApp.sendAction(closeAllAction, to: item.target, from: item)
        try expectEqual(primary.probe.shouldCloseCount, 1, "only the accessory parent is a command target")
        try expect(primary.window.childWindows == nil || primary.window.childWindows?.isEmpty == true, "parent cleanup detaches all accessories")
        try expect(accessoryProbes.allSatisfy { $0.shouldCloseCount == 0 && $0.willCloseCount == 0 }, "no accessory receives an independent close action")
        try expect(accessories.allSatisfy { !$0.isVisible }, "parent-owned cleanup leaves no visible accessory")
    }

    private static func nativeCloseItemAndFirstResponderRouteStayUntouched(
        menu: NSMenu,
        item closeAllItem: NSMenuItem
    ) throws {
        let closeItem = try expectValue(
            recursivelyCollectItems(in: menu, action: #selector(NSWindow.performClose(_:))).first,
            "generated menu must retain native performClose:"
        )
        let originalCloseTarget = closeItem.target
        let originalCloseAllTarget = closeAllItem.target
        let source = DeviceMirrorWindowPresenter()
        let selectedA = makeRegisteredMirror(deviceID: "selected-a", source: source)
        let selection = SelectedDeviceState(selectedDeviceID: "selected-a")
        let targetNilB = makeRegisteredMirror(deviceID: "target-nil-key-b", source: source)
        let stock = StockCloseAllProbe()
        closeAllItem.target = stock
        NSApp.mainMenu = menu
        let router = NativeCloseAllCommandRouter(
            primaryWindowSource: source,
            notificationCenter: NotificationCenter()
        )
        defer {
            closeAllItem.target = originalCloseAllTarget
            tearDown(selectedA.window)
            tearDown(targetNilB.window)
        }

        router.install()
        try expectEqual(selection.selectedDeviceID, "selected-a", "the controlled device selection must remain A")
        try expect(closeItem.target === originalCloseTarget, "Close All installation must not retarget native Close")
        try expect(closeItem.target == nil, "the generated Close item must retain target-nil responder routing")

        try makeKeyWithFirstResponder(targetNilB.window)
        try expect(NSApp.keyWindow === targetNilB.window, "B must be the real key window while A remains selected")
        try expect(
            NSApp.target(forAction: closeItem.action!, to: nil, from: closeItem) as? NSWindow === targetNilB.window,
            "target-nil generated Close must resolve through the responder chain to key B"
        )
        try expect(NSApp.sendAction(closeItem.action!, to: nil, from: closeItem), "target-nil generated Close must dispatch")
        try expectEqual(selectedA.probe.willCloseCount, 0, "selected A remains independent from key B's target-nil Close")
        try expectEqual(targetNilB.probe.willCloseCount, 1, "target-nil generated Close retires key B only")

        let commandWB = makeRegisteredMirror(deviceID: "command-w-key-b", source: source)
        defer { tearDown(commandWB.window) }
        try makeKeyWithFirstResponder(commandWB.window)
        try expect(NSApp.keyWindow === commandWB.window, "Cmd-W B must be the real key window while A remains selected")
        try expect(
            NSApp.target(forAction: closeItem.action!, to: nil, from: closeItem) as? NSWindow === commandWB.window,
            "generated Cmd-W must resolve through target-nil routing to key B"
        )
        let event = try expectValue(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: commandWB.window.windowNumber,
                context: nil,
                characters: "w",
                charactersIgnoringModifiers: "w",
                isARepeat: false,
                keyCode: 13
            ),
            "the local Cmd-W event must be constructible"
        )
        try expect(menu.performKeyEquivalent(with: event), "the generated native menu must consume Cmd-W")
        try expectEqual(selectedA.probe.willCloseCount, 0, "selected A remains independent from key B's Cmd-W")
        try expectEqual(commandWB.probe.willCloseCount, 1, "generated Cmd-W retires key B only")
    }

    private static func menuReplacementFailureRecoveryAndIdempotence(
        generatedMenu: NSMenu,
        generatedItem: NSMenuItem,
        metadata: MenuMetadata
    ) throws {
        let source = DeviceMirrorWindowPresenter()
        var diagnostics: [NativeCloseAllCommandRouter.BindingState] = []
        let center = NotificationCenter()
        let firstMenu = generatedMenu
        let firstItem = generatedItem
        let generatedOriginalTarget = generatedItem.target
        let firstStock = StockCloseAllProbe()
        firstItem.target = firstStock
        NSApp.mainMenu = firstMenu
        let router = NativeCloseAllCommandRouter(
            primaryWindowSource: source,
            notificationCenter: center,
            diagnosticHandler: { diagnostics.append($0) }
        )
        defer {
            NSApp.mainMenu = generatedMenu
            generatedItem.target = generatedOriginalTarget
        }
        router.install()
        try expect(firstItem.target === router, "initial generated item binds")

        let (replacementMenu, replacementItem) = controlledMenu(from: metadata)
        let replacementStock = StockCloseAllProbe()
        replacementItem.target = replacementStock
        NSApp.mainMenu = replacementMenu
        center.post(name: NSMenu.didBeginTrackingNotification, object: replacementItem.menu)
        try expect(firstItem.target === firstStock, "replacement restores the old router-owned target")
        try expect(replacementItem.target === router, "tracking synchronously binds the replacement item")
        _ = NSApp.sendAction(closeAllAction, to: replacementItem.target, from: replacementItem)
        try expectEqual(firstStock.actionCount, 0, "the obsolete generated item is never forwarded")
        try expectEqual(replacementStock.actionCount, 1, "the replacement stock target receives one action")

        let (laterMenu, laterItem) = controlledMenu(from: metadata)
        let laterStock = StockCloseAllProbe()
        let anotherOwner = StockCloseAllProbe()
        laterItem.target = laterStock
        replacementItem.target = anotherOwner
        NSApp.mainMenu = laterMenu
        center.post(name: NSMenu.didBeginTrackingNotification, object: laterItem.menu)
        try expect(replacementItem.target === anotherOwner, "replacement never overwrites another owner of the currently bound item")
        try expect(laterItem.target === router, "reconciliation still binds the later unique item")

        let (missingMenu, _) = controlledMenu(from: metadata)
        removeItems(in: missingMenu, action: closeAllAction)
        NSApp.mainMenu = missingMenu
        center.post(name: NSMenu.didBeginTrackingNotification, object: missingMenu)
        try expectEqual(router.bindingState, .missing, "zero matches transition to missing")
        try expect(laterItem.target === laterStock, "missing state restores the last router-owned target")
        let diagnosticsAfterMissing = diagnostics.count
        router.install()
        center.post(name: NSMenu.didRemoveItemNotification, object: missingMenu)
        drainMainQueue()
        try expectEqual(diagnostics.count, diagnosticsAfterMissing, "repeated missing reconciliation stays silent")

        let (ambiguousMenu, firstAmbiguousItem) = controlledMenu(from: metadata)
        let firstAmbiguousStock = StockCloseAllProbe()
        firstAmbiguousItem.target = firstAmbiguousStock
        let duplicate = try expectValue(firstAmbiguousItem.copy() as? NSMenuItem, "generated Close All item must be copyable")
        let duplicateStock = StockCloseAllProbe()
        duplicate.target = duplicateStock
        try expectValue(firstAmbiguousItem.menu, "generated Close All item must retain its File menu").addItem(duplicate)
        NSApp.mainMenu = ambiguousMenu
        center.post(name: NSMenu.didBeginTrackingNotification, object: duplicate.menu)
        try expectEqual(router.bindingState, .ambiguous(2), "two exact selector matches transition to ambiguous")
        try expect(firstAmbiguousItem.target === firstAmbiguousStock, "ambiguous candidate one keeps its stock target")
        try expect(duplicate.target === duplicateStock, "ambiguous candidate two keeps its stock target")
        let diagnosticsAfterAmbiguous = diagnostics.count
        center.post(name: NSMenu.didAddItemNotification, object: duplicate.menu)
        center.post(name: NSMenu.didAddItemNotification, object: duplicate.menu)
        drainMainQueue()
        try expectEqual(diagnostics.count, diagnosticsAfterAmbiguous, "coalesced repeated ambiguity stays silent")

        duplicate.menu?.removeItem(duplicate)
        center.post(name: NSMenu.didBeginTrackingNotification, object: firstAmbiguousItem.menu)
        try expectEqual(router.bindingState, .bound(ObjectIdentifier(firstAmbiguousItem)), "one remaining exact match recovers binding")
        router.install()
        router.install()
        let diagnosticsAfterRecovery = diagnostics.count
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        drainMainQueue()
        try expectEqual(diagnostics.count, diagnosticsAfterRecovery, "coalesced app reactivation stays idempotent")
        _ = NSApp.sendAction(closeAllAction, to: firstAmbiguousItem.target, from: firstAmbiguousItem)
        try expectEqual(firstAmbiguousStock.actionCount, 1, "recovered idempotent binding forwards once")
    }

    private static func lifecycleChangeDuringDispatchIsDeferred(
        generatedMenu: NSMenu,
        generatedItem: NSMenuItem,
        metadata: MenuMetadata
    ) throws {
        let source = DeviceMirrorWindowPresenter()
        let center = NotificationCenter()
        let primary = makeRegisteredMirror(deviceID: "fold", source: source)
        primary.probe.allowsClose = false
        var priorObserverCount = 0
        primary.window.closeAttemptObserver = { _ in priorObserverCount += 1 }
        let firstMenu = generatedMenu
        let firstItem = generatedItem
        let generatedOriginalTarget = generatedItem.target
        let firstStock = StockCloseAllProbe()
        firstItem.target = firstStock
        let (replacementMenu, replacementItem) = controlledMenu(from: metadata)
        let replacementStock = StockCloseAllProbe()
        replacementItem.target = replacementStock
        NSApp.mainMenu = firstMenu
        let router = NativeCloseAllCommandRouter(
            primaryWindowSource: source,
            notificationCenter: center
        )
        defer {
            NSApp.mainMenu = generatedMenu
            generatedItem.target = generatedOriginalTarget
            tearDown(primary.window)
        }
        firstStock.onAction = { _ in
            primary.window.performClose(firstItem)
            NSApp.mainMenu = replacementMenu
            center.post(name: NSMenu.didBeginTrackingNotification, object: replacementItem.menu)
            router.closeAll(firstItem)
        }

        router.install()
        _ = NSApp.sendAction(closeAllAction, to: firstItem.target, from: firstItem)
        try expectEqual(firstStock.actionCount, 1, "reentrant dispatch never forwards stock twice")
        try expectEqual(primary.probe.shouldCloseCount, 1, "the stock-vetoed primary is not attempted twice during reentrant lifecycle work")
        try expectEqual(priorObserverCount, 1, "the pre-existing observer runs during reentrant lifecycle work")
        primary.window.closeAttemptObserver?(primary.window)
        try expectEqual(priorObserverCount, 2, "the pre-existing observer is restored before deferred reconciliation")
        try expect(firstItem.target === firstStock, "deferred reconciliation restores the obsolete item")
        try expect(replacementItem.target === router, "deferred reconciliation binds the replacement after cleanup")
        _ = NSApp.sendAction(closeAllAction, to: replacementItem.target, from: replacementItem)
        try expectEqual(replacementStock.actionCount, 1, "the replacement forwards once after recovery")
    }

    private static func controlledMenu(from metadata: MenuMetadata) -> (NSMenu, NSMenuItem) {
        let mainMenu = NSMenu(title: "Main")
        let fileMenu = NSMenu(title: "File")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        let item = NSMenuItem(
            title: metadata.title,
            action: metadata.action,
            keyEquivalent: metadata.keyEquivalent
        )
        item.keyEquivalentModifierMask = metadata.modifiers
        fileMenu.addItem(item)
        return (mainMenu, item)
    }

#endif

    private static func makeRegisteredMirror(
        deviceID: String,
        source: DeviceMirrorWindowPresenter
    ) -> (window: SeamlessMirrorWindow, probe: CloseProbe) {
        let window = makeMirrorWindow()
        source.registerPrimaryWindow(window, forDeviceID: deviceID)
        let probe = CloseProbe(registryOwner: source)
        window.delegate = probe
        return (window, probe)
    }

    private static func makeMirrorWindow() -> SeamlessMirrorWindow {
        let window = SeamlessMirrorWindow(
            contentRect: NSRect(x: 40, y: 40, width: 432, height: 832),
            styleMask: MirrorWindowActivationPolicy.seamlessFocusableStyleMask(from: []),
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func makeOrdinaryWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 520, y: 40, width: 480, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func makeAccessoryPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        return panel
    }

    private static func uniqueCloseAllItem(in menu: NSMenu) throws -> NSMenuItem {
        let matches = recursivelyCollectItems(in: menu, action: closeAllAction)
        try expectEqual(matches.count, 1, "generated main menu must contain one exact closeAll: action")
        return matches[0]
    }

    private static func recursivelyCollectItems(in root: NSMenu, action: Selector) -> [NSMenuItem] {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ menu: NSMenu) -> [NSMenuItem] {
            guard visited.insert(ObjectIdentifier(menu)).inserted else { return [] }
            return menu.items.flatMap { item -> [NSMenuItem] in
                (item.action == action ? [item] : []) + (item.submenu.map(visit) ?? [])
            }
        }
        return visit(root)
    }

    private static func removeItems(in root: NSMenu, action: Selector) {
        for item in root.items {
            if item.action == action {
                root.removeItem(item)
            } else if let submenu = item.submenu {
                removeItems(in: submenu, action: action)
            }
        }
    }

    private static func drainMainQueue() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    private static func makeKeyWithFirstResponder(_ window: NSWindow) throws {
        let focus = FocusableView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = focus
        window.makeKeyAndOrderFront(nil)
        (NSApp as? NativeCloseAllTestApplication)?.testKeyWindow = window
        drainMainQueue()
        try expect(window.makeFirstResponder(focus), "key B's content must become first responder")
    }

    private static func tearDown(_ window: NSWindow) {
        if (NSApp as? NativeCloseAllTestApplication)?.testKeyWindow === window {
            (NSApp as? NativeCloseAllTestApplication)?.testKeyWindow = nil
        }
        window.delegate = nil
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.close()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        guard actual == expected else { throw Failure("\(message): expected \(expected), got \(actual)") }
    }

    private static func expectValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message) }
        return value
    }
}

@MainActor
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class SelectedDeviceState {
    var selectedDeviceID: String

    init(selectedDeviceID: String) {
        self.selectedDeviceID = selectedDeviceID
    }
}

@MainActor
private final class ApplicationCleanupProbe: NSObject, NSWindowDelegate {
    private(set) var sessionCloseCount = 0
    private(set) var leaseReleaseCount = 0
    private(set) var recordRemovalCount = 0

    func windowWillClose(_ notification: Notification) {
        sessionCloseCount += 1
        leaseReleaseCount += 1
        recordRemovalCount += 1
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
