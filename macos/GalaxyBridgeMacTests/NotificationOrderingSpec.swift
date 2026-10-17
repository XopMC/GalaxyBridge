@main
struct NotificationOrderingSpec {
    static func row(_ value: Int, id: String? = nil, package: String = "synthetic") -> BridgeNotificationRow {
        .init(id: id ?? String(value), packageName: package, appLabel: "Synthetic", title: "Local test",
            body: "", postedAt: Date(timeIntervalSince1970: Double(value)), actions: [], appIconPNG: nil)
    }
    static func compactEvent(_ input: [BridgeNotificationRow]) -> [BridgeNotificationRow] {
        var rows = input
        // ACTUAL_EVENT_COMPACTION
        return rows
    }
    static func presented(_ rows: [BridgeNotificationRow], muted: Set<String> = []) -> [BridgeNotificationRow] {
        // ACTUAL_PRESENTATION_RETURN
    }
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL \(message)\n", stderr); exit(1) }
    }
    static func main() {
        // Android sends the authoritative snapshot newest first. Prepending each
        // event must neither reverse it nor discard its newest 200 entries.
        var rows: [BridgeNotificationRow] = []
        for value in (0..<205).reversed() {
            rows.insert(row(value), at: 0)
            rows = compactEvent(rows)
        }
        require(rows.map(\.id) == (5..<205).reversed().map(String.init), "Initial snapshot lost or reversed newest notifications")
        rows.insert(row(-1), at: 0)
        require(compactEvent(rows).map(\.id) == (5..<205).reversed().map(String.init), "Late old event evicted a newer notification")
        let mixed = [row(1), row(30, package: "muted"), row(5), row(10)]
        require(presented(mixed, muted: ["muted"]).map(\.id) == ["10", "5", "1"], "Visible rows or recovered drafts are not newest first")
        let ties = [row(9, id: "b"), row(9, id: "a")]
        require(compactEvent(ties).map(\.id) == ["a", "b"] && presented(ties).map(\.id) == ["a", "b"], "Equal timestamps reorder cards nondeterministically")
        print("PASS actual notification models, event compaction and presentation: newest 200 retained, late old events, recovered drafts, filters and stable ties")
    }
}
