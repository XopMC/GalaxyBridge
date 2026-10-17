import Foundation

@main
private enum EnhancedRouteHandoffSpec {
    @MainActor static func main() async throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: message, code: 1) }
        }
        func plan(_ adb: String?, _ helper: String?, _ captures: Set<String>, ready: Bool = true,
                  retiring: Bool = false, windows: Bool = false) -> CaptureRouteHandoffPlan? {
            CaptureRouteHandoffPlan.resolve(deviceReady: ready, adbSerial: adb, helperDeviceID: helper,
                capturedSerials: captures, retirementsPending: retiring, windowsPending: windows)
        }
        try expect(plan("usb", "phone", ["usb"]) == nil, "a usable current route must not restart capture")
        try expect(plan(nil, "phone", ["usb"]) == .init(destinationSerial: "shell:phone", requiresMigration: true), "USB loss uses authenticated prepared LAN")
        try expect(plan("wifi", "phone", ["usb"]) == .init(destinationSerial: "wifi", requiresMigration: true), "verified Wireless ADB remains preferred and retains its QUIC path")
        try expect(plan("usb", "phone", ["shell:phone"]) == nil, "USB return must preserve a surviving Shell owner")
        try expect(plan("usb", "phone", ["shell:phone", "old-usb"], retiring: true)?.destinationSerial == "shell:phone", "mixed retirement cannot displace a surviving prepared owner")
        try expect(plan(nil, nil, ["usb"]) == nil, "no route cannot admit a replacement")
        try expect(plan(nil, "phone", ["usb"], ready: false) == nil, "advertisement without current readiness is insufficient")
        try expect(plan(nil, "phone", [], windows: true) == .init(destinationSerial: "shell:phone", requiresMigration: false), "confirmed pending windows can resume without another retirement")
        try expect(plan("usb", nil, [], retiring: true)?.requiresMigration == false, "a returned route can settle existing tombstones without interrupting another owner")
        let capturedKey = Data(repeating: 1, count: 32)
        let capturedPeer = VerifiedCaptureRetirementPeer(logicalDeviceID: "device:phone",
            bindingDeviceID: "phone", publicKeySHA256: capturedKey, bindingVerified: true)
        try expect(capturedPeer != nil, "verified capture freezes its phone key before launch")
        try expect(capturedPeer!.accepts(deviceID: "phone", publicKeySHA256: capturedKey, authenticated: true), "same authenticated phone may attest absence")
        try expect(!capturedPeer!.accepts(deviceID: "other-phone", publicKeySHA256: capturedKey, authenticated: true), "another phone cannot attest captured ownership")
        try expect(!capturedPeer!.accepts(deviceID: "phone", publicKeySHA256: Data(repeating: 2, count: 32), authenticated: true), "replacement phone key cannot inherit old cleanup authority")
        try expect(!capturedPeer!.accepts(deviceID: "phone", publicKeySHA256: capturedKey, authenticated: false), "discovery alone is insufficient for absence proof")
        try expect(VerifiedCaptureRetirementPeer(logicalDeviceID: "device:other", bindingDeviceID: "phone", publicKeySHA256: capturedKey, bindingVerified: true) == nil, "logical phone identity is checked at capture")
        try expect(VerifiedCaptureRetirementPeer(logicalDeviceID: "device:phone", bindingDeviceID: "phone", publicKeySHA256: capturedKey, bindingVerified: false) == nil, "unverified ADB route cannot acquire Helper proof authority")
        try expect(VerifiedCaptureRetirementPeer(logicalDeviceID: "device:phone", bindingDeviceID: "phone", publicKeySHA256: Data(), bindingVerified: true) == nil, "missing fingerprint cannot authorize cross-transport proof")
        let identity = Data([1, 2, 3])
        let route = VerifiedEnhancedRetirementRoute(logicalDeviceID: "device:phone", captureSerial: "usb", routeSerial: "wifi",
            captureBindingDeviceID: "phone", routeBindingDeviceID: "phone", captureIdentity: identity,
            routeIdentity: identity, routeCurrentlyVerified: true)
        try expect(route != nil, "verified same-device alias permits retirement")
        try expect(VerifiedEnhancedRetirementRoute(logicalDeviceID: "device:phone", captureSerial: "usb", routeSerial: "other",
            captureBindingDeviceID: "phone", routeBindingDeviceID: "other-phone", captureIdentity: identity,
            routeIdentity: identity, routeCurrentlyVerified: true) == nil, "another phone cannot retire captured SCID")
        try expect(VerifiedEnhancedRetirementRoute(logicalDeviceID: "device:phone", captureSerial: "usb", routeSerial: "wifi",
            captureBindingDeviceID: "phone", routeBindingDeviceID: "phone", captureIdentity: identity,
            routeIdentity: Data([9]), routeCurrentlyVerified: true) == nil, "device-name/ID match without key identity is insufficient")
        let fence = EnhancedRemoteRetirementFence(captureSerial: "usb")
        fence.requireRetirement(scid: 17)
        try expect(!fence.settled, "remote owner remains fenced until cleanup proof")
        await fence.retire { _, _ in throw NSError(domain: "USB detached", code: 1) }
        try expect(!fence.settled, "failed cleanup cannot claim settlement")
        try expect(fence.install(route!), "same-device route is admitted")
        var retired: [(String, UInt32)] = []
        await fence.retire { serial, scid in retired.append((serial, scid)) }
        try expect(retired.count == 1 && retired[0].0 == "wifi" && retired[0].1 == 17, "reachable alias retires exact old SCID")
        try expect(fence.settled, "remote absence proof releases remote fence")

        let inFlight = EnhancedRemoteRetirementFence(captureSerial: "usb")
        inFlight.requireRetirement(scid: 23)
        var attemptedRoutes: [String] = []
        await inFlight.retire { serial, scid in
            attemptedRoutes.append(serial)
            try expect(scid == 23, "route change must not broaden old SCID ownership")
            if serial == "usb" {
                _ = inFlight.install(route!)
                throw NSError(domain: "USB detached during cleanup", code: 1)
            }
        }
        try expect(attemptedRoutes == ["usb", "wifi"] && inFlight.settled, "in-flight failure retries exact SCID through newly verified alias")
        let otherCapture = EnhancedRemoteRetirementFence(captureSerial: "different-usb")
        try expect(!otherCapture.install(route!), "cleanup alias cannot transfer to another captured owner")

        var demand = PrimaryScreenDemandRegistry()
        _ = demand.acquire(deviceID: "device:phone", consumer: .viewer)
        let permit = demand.beginRetirement("device:phone")
        fence.requireRetirement(scid: 18)
        let nativeSettled = false
        if nativeSettled && fence.settled { _ = demand.finishRetirement(permit) }
        try expect(!demand.canStart("device:phone"), "replacement cannot overlap native/remote owner")
        await fence.retire { _, _ in }
        if true && fence.settled { _ = demand.finishRetirement(permit) }
        try expect(demand.canStart("device:phone"), "joint native and remote proof admits successor")
        print("EnhancedRouteHandoffSpec passed")
    }
}
