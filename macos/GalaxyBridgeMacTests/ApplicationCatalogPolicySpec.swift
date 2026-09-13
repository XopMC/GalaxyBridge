import Foundation

@main
private enum ApplicationCatalogPolicySpec {
    static func main() throws {
        expect(
            ApplicationCatalogPolicy.resolve(isStoreBuild: false, hasEnhancedTransport: true) == .available,
            "Internal/Developer ID direct connections must expose the app catalog"
        )
        expect(
            ApplicationCatalogPolicy.resolve(isStoreBuild: false, hasEnhancedTransport: false) ==
                .unavailable(.directConnectionRequired),
            "LAN-only sessions must explain why independent app windows are unavailable"
        )
        expect(
            ApplicationCatalogPolicy.resolve(isStoreBuild: true, hasEnhancedTransport: true) ==
                .unavailable(.storeBuildUnsupported),
            "Mac App Store builds must never expose the enhanced launcher"
        )
        expect(
            ApplicationCatalogPolicy.hasDirectTransport(adbSerial: "TESTPHONE01"),
            "a live ADB row must keep app windows available when screen media is routed over Companion LAN"
        )
        expect(
            !ApplicationCatalogPolicy.hasDirectTransport(adbSerial: nil),
            "a pure Companion LAN row must not expose enhanced application windows"
        )
        let lanOnlyLoad = ApplicationCatalogLoadKey(deviceID: "device:phone-a", adbSerial: nil)
        let enhancedLoad = ApplicationCatalogLoadKey(
            deviceID: "device:phone-a",
            adbSerial: "TESTPHONE01"
        )
        expect(
            lanOnlyLoad != enhancedLoad,
            "the catalog task must rerun when a late ADB binding upgrades an already visible LAN row"
        )

        checkIndependentSessionBudgets()

        let limitDiagnostic = "application-window-limit"
        expect(
            ApplicationWindowDiagnosticPolicy.afterReservation(
                reserved: false,
                currentDiagnostic: nil,
                limitDiagnostic: limitDiagnostic
            ) == limitDiagnostic,
            "a rejected reservation must expose the application-window limit"
        )
        expect(
            ApplicationWindowDiagnosticPolicy.afterReservation(
                reserved: true,
                currentDiagnostic: limitDiagnostic,
                limitDiagnostic: limitDiagnostic
            ) == nil,
            "a successful reservation must clear a stale application-window limit"
        )
        expect(
            ApplicationWindowDiagnosticPolicy.afterRelease(
                currentDiagnostic: limitDiagnostic,
                limitDiagnostic: limitDiagnostic
            ) == nil,
            "closing an application window must clear a stale application-window limit immediately"
        )
        expect(
            ApplicationWindowDiagnosticPolicy.afterRelease(
                currentDiagnostic: "camera-failed",
                limitDiagnostic: limitDiagnostic
            ) == "camera-failed",
            "releasing an application window must preserve unrelated diagnostics"
        )

        let item = ApplicationCatalogItem(
            packageName: "com.samsung.android.app.notes",
            componentName: "com.samsung.android.app.notes/.NotesActivity",
            label: "Samsung Notes",
            iconPNG: Data([0x89, 0x50, 0x4E, 0x47]),
            isSystem: false
        )
        expect(item.id == item.packageName, "catalog identity must remain stable across icon refreshes")

        var companionTextCalls = 0
        var scrcpyTexts: [String] = []
        let appWindowDestination = EnhancedTextInputDispatcher.send(
            "Galaxy",
            context: .independentApplicationDisplay,
            companion: { _ in
                companionTextCalls += 1
                return true
            },
            scrcpy: { scrcpyTexts.append($0) }
        )
        expect(
            appWindowDestination == .companion,
            "an independent app window must prefer the Unicode-capable Accessibility bridge"
        )
        expect(
            companionTextCalls == 1 && scrcpyTexts.isEmpty,
            "independent app text must use the focused virtual display editor when Accessibility is available"
        )

        companionTextCalls = 0
        scrcpyTexts.removeAll()
        let appWindowFallbackDestination = EnhancedTextInputDispatcher.send(
            "Fallback",
            context: .independentApplicationDisplay,
            companion: { _ in
                companionTextCalls += 1
                return false
            },
            scrcpy: { scrcpyTexts.append($0) }
        )
        expect(
            appWindowFallbackDestination == .scrcpy,
            "an independent app window must fall back to its scrcpy session when Accessibility is unavailable"
        )
        expect(
            companionTextCalls == 1 && scrcpyTexts == ["Fallback"],
            "the scrcpy fallback must preserve the complete committed text"
        )

        companionTextCalls = 0
        scrcpyTexts.removeAll()
        let primaryDestination = EnhancedTextInputDispatcher.send(
            "Bridge",
            context: .primaryDisplay,
            companion: { _ in
                companionTextCalls += 1
                return true
            },
            scrcpy: { scrcpyTexts.append($0) }
        )
        expect(
            primaryDestination == .companion && companionTextCalls == 1 && scrcpyTexts.isEmpty,
            "the primary display may prefer the companion text bridge when it accepts the text"
        )
        let primaryFallback = EnhancedTextInputDispatcher.send(
            "Fallback",
            context: .primaryDisplay,
            companion: { _ in false },
            scrcpy: { scrcpyTexts.append($0) }
        )
        expect(
            primaryFallback == .scrcpy && scrcpyTexts == ["Fallback"],
            "the primary display must fall back to scrcpy when the companion rejects the text"
        )

        var companionClipboardCommands: [EnhancedClipboardOperation] = []
        var scrcpyClipboardReads: [EnhancedClipboardReadRequest] = []
        let clipboardDestination = EnhancedClipboardRequestDispatcher.request(
            .copy,
            companion: {
                companionClipboardCommands.append($0)
                return true
            },
            scrcpy: { scrcpyClipboardReads.append($0) }
        )
        expect(
            clipboardDestination == .companion &&
                companionClipboardCommands == [.copy] &&
                scrcpyClipboardReads == [.readCurrent],
            "Accessibility must perform copy in the focused virtual editor before scrcpy reads it"
        )

        companionClipboardCommands.removeAll()
        scrcpyClipboardReads.removeAll()
        let clipboardFallback = EnhancedClipboardRequestDispatcher.request(
            .cut,
            companion: {
                companionClipboardCommands.append($0)
                return false
            },
            scrcpy: { scrcpyClipboardReads.append($0) }
        )
        expect(
            clipboardFallback == .scrcpy &&
                companionClipboardCommands == [.cut] &&
                scrcpyClipboardReads == [.atomicCut],
            "without Accessibility, scrcpy must perform an atomic cut-and-read"
        )

        var companionKeys: [(Bool, UInt32, UInt32, UInt32)] = []
        var scrcpyKeyCalls = 0
        let keyDestination = EnhancedKeyInputDispatcher.send(
            isDown: true,
            keycode: 29,
            repeatCount: 0,
            modifiers: 0x3000,
            companion: { isDown, keycode, repeatCount, modifiers in
                companionKeys.append((isDown, keycode, repeatCount, modifiers))
                return true
            },
            scrcpy: { scrcpyKeyCalls += 1 }
        )
        expect(
            keyDestination == .companion && companionKeys.count == 1 && scrcpyKeyCalls == 0,
            "independent app shortcuts and navigation must prefer the focused Accessibility window"
        )

        companionKeys.removeAll()
        let keyFallback = EnhancedKeyInputDispatcher.send(
            isDown: false,
            keycode: 29,
            repeatCount: 0,
            modifiers: 0x3000,
            companion: { isDown, keycode, repeatCount, modifiers in
                companionKeys.append((isDown, keycode, repeatCount, modifiers))
                return false
            },
            scrcpy: { scrcpyKeyCalls += 1 }
        )
        expect(
            keyFallback == .scrcpy && companionKeys.count == 1 && scrcpyKeyCalls == 1,
            "scrcpy remains the complete key fallback when Accessibility is unavailable"
        )

        var presentation = ApplicationWindowPresentationState()
        expect(
            presentation.phase == .opening && presentation.showsOpeningOverlay,
            "an app window must remain covered until a decoded frame is actually presented"
        )
        presentation.handle(.firstDecodedFrame)
        expect(
            presentation.phase == .opening && presentation.showsOpeningOverlay,
            "a pre-launch black frame received before control readiness must not uncover the app window"
        )
        presentation.handle(.controlReady)
        expect(
            presentation.phase == .controlReady && presentation.showsOpeningOverlay,
            "control readiness alone must not remove the opening overlay"
        )
        presentation.handle(.firstDecodedFrame)
        expect(
            presentation.phase == .presenting && !presentation.showsOpeningOverlay,
            "the first decoded frame must remove the opening overlay"
        )
        presentation.handle(.controlReady)
        expect(
            presentation.phase == .presenting,
            "late or duplicate control readiness must not regress a presented window"
        )
        presentation.reset()
        expect(
            presentation.phase == .opening && presentation.showsOpeningOverlay,
            "a reconnect must wait for its own first decoded frame"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyBridgeIconCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = CatalogSpecClock(now: Date(timeIntervalSince1970: 1_000))
        let cache = try ApplicationIconCache(
            rootURL: directory,
            retention: 30 * 24 * 60 * 60,
            maximumEntries: 2,
            maximumIconBytes: 48,
            now: { clock.now }
        )
        do {
            try cache.store(Data([1, 2, 3]), deviceID: "phone-a", packageName: "com.example.bad")
            fatalError("arbitrary bytes must never enter the icon cache")
        } catch ApplicationIconCacheError.invalidPNG {
            // Expected.
        }
        do {
            try cache.store(Self.png(width: 0, height: 128), deviceID: "phone-a", packageName: "com.example.zero")
            fatalError("zero-sized PNG metadata must never enter the icon cache")
        } catch ApplicationIconCacheError.invalidPNG {
            // Expected.
        }
        do {
            try cache.store(
                Self.png(width: 128, height: 128) + Data(repeating: 0, count: 64),
                deviceID: "phone-a",
                packageName: "com.example.large"
            )
            fatalError("oversized PNG data must never enter the icon cache")
        } catch ApplicationIconCacheError.iconTooLarge {
            // Expected.
        }
        let firstPNG = Self.png(width: 128, height: 128, marker: 1)
        let secondPNG = Self.png(width: 128, height: 128, marker: 2)
        let thirdPNG = Self.png(width: 128, height: 128, marker: 3)
        try cache.store(firstPNG, deviceID: "phone-a", packageName: "com.example.one")
        let freshIcon = try cache.iconPNG(deviceID: "phone-a", packageName: "com.example.one")
        expect(
            freshIcon == firstPNG,
            "fresh app icons must be reusable without another phone query"
        )
        clock.now.addTimeInterval(30 * 24 * 60 * 60 + 1)
        let expiredIcon = try cache.iconPNG(deviceID: "phone-a", packageName: "com.example.one")
        expect(
            expiredIcon == nil,
            "app icon cache must expire after 30 days"
        )
        clock.now = Date(timeIntervalSince1970: 10_000)
        try cache.store(firstPNG, deviceID: "phone-a", packageName: "com.example.one")
        clock.now.addTimeInterval(1)
        try cache.store(secondPNG, deviceID: "phone-a", packageName: "com.example.two")
        clock.now.addTimeInterval(1)
        try cache.store(thirdPNG, deviceID: "phone-a", packageName: "com.example.three")
        let oldestIcon = try cache.iconPNG(deviceID: "phone-a", packageName: "com.example.one")
        let middleIcon = try cache.iconPNG(deviceID: "phone-a", packageName: "com.example.two")
        let newestIcon = try cache.iconPNG(deviceID: "phone-a", packageName: "com.example.three")
        expect(oldestIcon == nil,
               "icon cache must prune the oldest entry at its bound")
        expect(middleIcon == secondPNG,
               "icon cache pruning must retain newer entries")
        expect(newestIcon == thirdPNG,
               "icon cache pruning must retain the newest entry")

        print("PASS application catalog policy, session budget, and bounded icon cache")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    private static func checkIndependentSessionBudgets() {
        var failures: [String] = []
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            assertions += 1
            if !condition { failures.append(message) }
        }

        let a = "device:phone-a"
        let b = "device:phone-b"
        let c = "device:phone-c"
        let d = "device:phone-d"
        // Duplicate logical IDs represent already coalesced USB/LAN routes,
        // not additional physical phones. Never deduplicate by display name.
        for physicalIDs in [[a, b, a, b], [a, b, c, a, c], []] {
            let model = ApplicationSessionBudgetProbe()
            model.activePhysicalLogicalSessionIDs = Set(physicalIDs)
            let context = "\(model.activePhysicalLogicalSessionIDs.count) connected phones"
            check(model.reserveApplicationWindowSession("app:a:notes"), "First app with \(context)")
            check(model.reserveApplicationWindowSession("app:b:calculator"), "Second app with \(context)")
            check(model.reserveApplicationWindowSession("app:a:browser"), "Third app with \(context)")
            check(!model.reserveApplicationWindowSession("app:c:files"), "Fourth app remains rejected with \(context)")
            check(model.applicationSessionLeases.leasedSessionIDs == ["app:a:notes", "app:b:calculator", "app:a:browser"],
                  "App budget contains only the three real window leases with \(context)")
            check(model.reserveApplicationWindowSession("app:b:calculator"), "Reopen is idempotent at app capacity")

            check(model.canStartLogicalSession(a), "Existing/first physical phone must not be blocked by full app budget")
            if model.activePhysicalLogicalSessionIDs.count < 3 {
                check(model.canStartLogicalSession(c), "New physical phone below device capacity ignores app budget")
            } else {
                check(!model.canStartLogicalSession(d), "Fourth physical phone remains rejected")
                check(model.canStartLogicalSession(c), "Reconnect at physical capacity remains allowed")
            }

            model.releaseApplicationWindowSession("app:b:calculator")
            check(model.applicationSessionLeases.leasedSessionIDs == ["app:a:notes", "app:a:browser"],
                  "Closing a window frees only its own app lease")
            check(model.reserveApplicationWindowSession("app:c:files"), "Freed app capacity is immediately reusable")
            model.releaseApplicationWindowSession("app:never-opened")
            check(model.applicationSessionLeases.leasedSessionIDs == ["app:a:notes", "app:a:browser", "app:c:files"],
                  "Duplicate/unknown close does not release unrelated app leases")
            check(model.activePhysicalLogicalSessionIDs == Set(physicalIDs),
                  "App reservation/release cannot drop physical sessions")

            model.activePhysicalLogicalSessionIDs = [a, b, c]
            check(!model.canStartLogicalSession(d), "Physical capacity stays three regardless of earlier app operations")
            model.activePhysicalLogicalSessionIDs.remove(c)
            check(model.canStartLogicalSession(d), "Freed physical capacity recovers even with three app leases")
            check(model.applicationSessionLeases.leasedSessionIDs.count == 3,
                  "Physical admission does not evict app leases")
        }

        if !failures.isEmpty {
            failures.forEach { print("FAIL \($0)") }
            print("FAILED \(failures.count) of \(assertions) independent session-budget assertions")
            exit(1)
        }
        print("PASS \(assertions) independent device/app budget assertions through AppModel admission and lease methods")
    }

    private static func png(width: UInt32, height: UInt32, marker: UInt8 = 0) -> Data {
        var bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52,
        ]
        for value in [width, height] {
            bytes.append(UInt8((value >> 24) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        }
        bytes.append(marker)
        return Data(bytes)
    }
}

private final class CatalogSpecClock: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}
