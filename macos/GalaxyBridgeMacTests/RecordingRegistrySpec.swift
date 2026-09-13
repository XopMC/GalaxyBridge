import Foundation

@main
enum RecordingRegistrySpec {
    static func main() {
        var registry = RecordingRegistry<String>()
        let a = registry.insert(sink: "file A", deviceID: "provisional-A", deviceName: "Galaxy")
        let b = registry.insert(sink: "file B", deviceID: "B", deviceName: "Galaxy")
        precondition(a != b)
        precondition(registry.sinks(for: "provisional-A") == ["file A"])
        registry.migrate(from: "provisional-A", to: "verified-A")
        precondition(registry.sinks(for: "provisional-A").isEmpty)
        precondition(registry.sinks(for: "verified-A") == ["file A"])
        precondition(registry.summaries.first(where: { $0.id == a })?.deviceName == "Galaxy")
        let stopped = registry.remove(id: a)
        precondition(stopped?.sink == "file A")
        precondition(stopped?.summary.deviceID == "verified-A")
        precondition(registry.sinks(for: "verified-A").isEmpty)
        precondition(registry.remove(id: a) == nil)
        precondition(registry.sinks(for: "B") == ["file B"])
        // When two provisional routes become one verified phone, neither file
        // may be silently replaced. Each recording retains an independent Stop.
        let c = registry.insert(sink: "file C", deviceID: "alias-B", deviceName: "Phone C")
        registry.migrate(from: "alias-B", to: "B")
        precondition(Set(registry.sinks(for: "B")) == Set(["file B", "file C"]))
        precondition(registry.remove(id: c)?.sink == "file C")
        precondition(registry.sinks(for: "B") == ["file B"])
        precondition(registry.remove(deviceID: "B").map(\.sink) == ["file B"])
        precondition(registry.summaries.isEmpty)
        precondition(registry.remove(deviceID: "B").isEmpty)
        print("PASS recording identity, route migration, exact Stop, duplicate Stop and merged routes")
    }
}
