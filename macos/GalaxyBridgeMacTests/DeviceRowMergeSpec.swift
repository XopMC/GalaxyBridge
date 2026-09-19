import Foundation
import GalaxyBridgeCore

// Supply SwiftPM's resource accessor to this standalone production-code test.
extension Bundle {
    static var module: Bundle {
        Bundle(path: ProcessInfo.processInfo.environment["GB_ROW_TEST_RESOURCES"]!)!
    }
}

@main
private enum DeviceRowMergeSpec {
    static func main() {
        var failures: [String] = []
        var checked = 0

        func check(_ condition: Bool, _ message: String) {
            checked += 1
            if !condition { failures.append(message) }
        }

        func row(_ transport: TransportKind, ready: Bool, serial: String? = nil) -> DeviceRow {
            DeviceRow(
                id: "device:trusted-fold", name: transport == .companionLAN ? "My Fold" : "SM-F946B",
                subtitle: "", transport: transport, isReady: ready, adbSerial: serial,
                companionID: transport == .companionLAN ? "bonjour:trusted-fold" : nil
            )
        }

        let usb = row(.usbADB, ready: true, serial: "USB-FOLD")
        let wifi = row(.wirelessADB, ready: true, serial: "192.168.42.40:39643")
        for pair in [[wifi, usb], [usb, wifi]] {
            let merged = DeviceRowMerger.merge(pair[0], pair[1])
            check(merged.transport == .usbADB, "Ready USB must win in both input orders")
            check(merged.adbSerial == "USB-FOLD", "USB-selected row must address USB, not earlier Wi-Fi")
        }

        // Literal expected routes distinguish priority from enumeration order.
        // In the all-offline case, retain the highest-priority known route for
        // reconnect presentation, but never mark it ready.
        let readinessCases: [(Bool, Bool, Bool, TransportKind, String?, Bool)] = [
            (true, true, true, .usbADB, "USB-FOLD", true),
            (true, true, false, .usbADB, "USB-FOLD", true),
            (true, false, true, .usbADB, "USB-FOLD", true),
            (true, false, false, .usbADB, "USB-FOLD", true),
            (false, true, true, .wirelessADB, "192.168.42.40:39643", true),
            (false, true, false, .wirelessADB, "192.168.42.40:39643", true),
            (false, false, true, .companionLAN, nil, true),
            (false, false, false, .usbADB, "USB-FOLD", false),
        ]
        let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for (usbReady, wifiReady, lanReady, expectedTransport, expectedSerial, expectedReady) in readinessCases {
            let routes = [
                row(.usbADB, ready: usbReady, serial: "USB-FOLD"),
                row(.wirelessADB, ready: wifiReady, serial: "192.168.42.40:39643"),
                row(.companionLAN, ready: lanReady),
            ]
            for order in permutations {
                let merged = DeviceRowMerger.merge(
                    DeviceRowMerger.merge(routes[order[0]], routes[order[1]]), routes[order[2]]
                )
                let label = "readiness=\(usbReady),\(wifiReady),\(lanReady) order=\(order)"
                check(merged.transport == expectedTransport, "Wrong selected route: \(label)")
                check(merged.adbSerial == expectedSerial, "Serial not owned by selected route: \(label)")
                check(merged.isReady == expectedReady, "Readiness must describe usable route: \(label)")
                check(merged.id == "device:trusted-fold", "Logical identity changed: \(label)")
                check(merged.companionID == "bonjour:trusted-fold", "Companion endpoint lost: \(label)")
                check(merged.name == "My Fold", "Companion display name lost: \(label)")
            }
        }

        // An incomplete ADB row may not borrow another transport's serial.
        let incompleteUSB = row(.usbADB, ready: true)
        for pair in [[incompleteUSB, wifi], [wifi, incompleteUSB]] {
            let merged = DeviceRowMerger.merge(pair[0], pair[1])
            check(merged.transport == .usbADB && merged.adbSerial == nil,
                  "Missing selected serial must fail closed, not route commands elsewhere")
        }

        // Stale input data on a LAN row must not expose an enhanced route.
        let lan = row(.companionLAN, ready: true, serial: "STALE-ADB")
        let offlineUSB = row(.usbADB, ready: false, serial: "USB-FOLD")
        for pair in [[lan, offlineUSB], [offlineUSB, lan]] {
            let merged = DeviceRowMerger.merge(pair[0], pair[1])
            check(merged.transport == .companionLAN && merged.adbSerial == nil,
                  "LAN fallback must not retain ADB availability")
        }

        // Verified Wi-Fi aliases may describe the same logical device. Keep
        // an equally ranked choice stable rather than depending on ADB order.
        for ready in [false, true] {
            let address = row(.wirelessADB, ready: ready, serial: "192.168.42.40:39643")
            let alias = row(.wirelessADB, ready: ready, serial: "adb-trusted-fold._adb-tls-connect._tcp")
            for pair in [[address, alias], [alias, address]] {
                let merged = DeviceRowMerger.merge(pair[0], pair[1])
                check(merged.adbSerial == "192.168.42.40:39643" && merged.isReady == ready,
                      "Equal-priority known routes need deterministic serial selection")
            }
        }

        check(
            !ADBPendingIdentityPresentationPolicy.shouldPublishStandalone(
                hasCanonicalCompanionRow: true,
                hasPersistentlyVerifiedBinding: true,
                matchingCompanionCount: 0
            ),
            "A known signed alias awaiting live validation must not duplicate its canonical phone"
        )
        check(
            !ADBPendingIdentityPresentationPolicy.shouldPublishStandalone(
                hasCanonicalCompanionRow: true,
                hasPersistentlyVerifiedBinding: false,
                matchingCompanionCount: 1
            ),
            "One unambiguous binding candidate must remain hidden until signed proof completes"
        )
        check(
            !ADBPendingIdentityPresentationPolicy.shouldPublishStandalone(
                hasCanonicalCompanionRow: false,
                hasPersistentlyVerifiedBinding: true,
                matchingCompanionCount: 1
            ),
            "ADB-only discovery must not manufacture a sidebar device before explicit pairing"
        )
        check(
            !ADBPendingIdentityPresentationPolicy.shouldPublishStandalone(
                hasCanonicalCompanionRow: true,
                hasPersistentlyVerifiedBinding: false,
                matchingCompanionCount: 2
            ),
            "ambiguous same-model ADB routes must remain hidden until signed identity proof completes"
        )

        check(
            !CompanionDiscoveryPresentationPolicy.shouldPublish(hasCommittedPeer: false),
            "an unpaired Helper advertisement must not create a device on clean launch"
        )
        check(
            CompanionDiscoveryPresentationPolicy.shouldPublish(hasCommittedPeer: true),
            "a committed peer may be presented when its Helper is discovered"
        )

        check(
            PersistedWirelessADBBindingPolicy.canRestoreTrustedRoute(
                identityBindingIsVerified: true,
                storedHardwareSerial: " TESTPHONE01\n",
                currentHardwareSerial: "TESTPHONE01"
            ),
            "A signed alias with the exact hardware serial must survive application restart"
        )
        check(
            !PersistedWirelessADBBindingPolicy.canRestoreTrustedRoute(
                identityBindingIsVerified: false,
                storedHardwareSerial: "TESTPHONE01",
                currentHardwareSerial: "TESTPHONE01"
            ),
            "A hardware match cannot replace signed identity verification"
        )
        check(
            !PersistedWirelessADBBindingPolicy.canRestoreTrustedRoute(
                identityBindingIsVerified: true,
                storedHardwareSerial: "TESTPHONE01",
                currentHardwareSerial: "TESTPHONE02"
            ),
            "A reused network endpoint must fail closed when hardware identity changes"
        )
        for missing in [nil, "", "  \n"] as [String?] {
            check(
                !PersistedWirelessADBBindingPolicy.canRestoreTrustedRoute(
                    identityBindingIsVerified: true,
                    storedHardwareSerial: missing,
                    currentHardwareSerial: "TESTPHONE01"
                ),
                "A missing stored hardware serial must require a fresh signed proof"
            )
            check(
                !PersistedWirelessADBBindingPolicy.canRestoreTrustedRoute(
                    identityBindingIsVerified: true,
                    storedHardwareSerial: "TESTPHONE01",
                    currentHardwareSerial: missing
                ),
                "An unavailable live hardware serial must require a fresh signed proof"
            )
        }

        let fold5WiFi = "192.168.42.40:39643"
        let fold5USB = "TESTPHONE02"
        check(
            !ADBHardwareQAIsolationPolicy.routeIsExcluded(
                serial: fold5WiFi,
                requiredSerial: fold5WiFi,
                boundHardwareSerial: fold5USB,
                boundDeviceID: "fold5",
                excludedSerials: [fold5USB],
                excludedDeviceIDs: []
            ),
            "The exact QA route must survive exclusion of its sibling USB alias"
        )
        check(
            ADBHardwareQAIsolationPolicy.routeIsExcluded(
                serial: "192.168.42.16:35819",
                requiredSerial: fold5WiFi,
                boundHardwareSerial: "TESTPHONE03",
                boundDeviceID: "ordinary-fold8",
                excludedSerials: ["TESTPHONE03"],
                excludedDeviceIDs: ["ordinary-fold8"]
            ),
            "Alias-wide exclusions must still protect every non-selected phone"
        )

        if !failures.isEmpty {
            for failure in failures { print("FAIL \(failure)") }
            print("FAILED \(failures.count) of \(checked) route assertions")
            exit(1)
        }
        print("PASS \(checked) device-row assertions: selected serial, 48 route permutations/readiness cases, persisted identity and LAN fallback")
    }
}
