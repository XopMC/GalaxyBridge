import Foundation

@main struct PrimaryScreenDemandSpec {
    static func main() {
        var owner = PrimaryScreenDemandRegistry()
        let viewer = owner.acquire(deviceID: "adb:A", consumer: .viewer)
        let recording = owner.acquire(deviceID: "adb:A", consumer: .recording)
        let other = owner.acquire(deviceID: "B", consumer: .viewer)
        precondition(owner.canStart("adb:A") && owner.hasViewer("adb:A"))
        owner.migrate(from: "adb:A", to: "device:A")
        precondition(owner.deviceID(for: viewer) == "device:A")
        precondition(owner.release(viewer) == "device:A")
        precondition(owner.release(viewer) == nil)
        precondition(owner.canStart("device:A") && !owner.hasViewer("device:A"))
        precondition(owner.release(recording) == "device:A")
        let old = owner.beginRetirement("device:A")
        let reopened = owner.acquire(deviceID: "device:A", consumer: .viewer)
        precondition(!owner.canStart("device:A") && owner.canStart("B"))
        _ = owner.release(reopened)
        precondition(owner.finishRetirement(old) == "device:A")
        precondition(!owner.canStart("device:A")) // close during cleanup cannot resurrect
        let next = owner.acquire(deviceID: "adb:A2", consumer: .viewer)
        let first = owner.beginRetirement("adb:A2")
        let second = owner.beginRetirement("device:A")
        owner.migrate(from: "adb:A2", to: "device:A")
        precondition(owner.finishRetirement(first) == "device:A")
        precondition(!owner.canStart("device:A")) // other alias still draining
        precondition(owner.finishRetirement(first) == nil)
        _ = owner.finishRetirement(second)
        precondition(owner.canStart("device:A"))
        owner.revoke("device:A")
        precondition(owner.release(next) == nil && !owner.canStart("device:A"))
        precondition(owner.release(other) == "B")
        _ = owner.acquire(deviceID: "C", consumer: .recording)
        owner.removeAllDemand()
        precondition(!owner.canStart("C"))
        print("Primary screen demand: exact release, video demand, reopen barriers, alias merge, revoke and Quit PASS")
    }
}
