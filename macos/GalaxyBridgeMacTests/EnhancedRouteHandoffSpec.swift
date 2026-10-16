import Foundation

@main
private enum EnhancedRouteHandoffSpec {
    @MainActor static func main() async throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: message, code: 1) }
        }
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
