import Foundation

struct ActiveRecordingSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let deviceID: String
    let deviceName: String
}

/// MainActor-owned by AppModel. Recording identity outlives a device row,
/// selection or window; verified identity migration changes only frame routing.
struct RecordingRegistry<Sink> {
    struct Entry {
        var summary: ActiveRecordingSummary
        let sink: Sink
    }

    private var entries: [UUID: Entry] = [:]

    var summaries: [ActiveRecordingSummary] {
        entries.values.map(\.summary).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    mutating func insert(sink: Sink, deviceID: String, deviceName: String, id: UUID = UUID()) -> UUID {
        precondition(entries[id] == nil)
        entries[id] = Entry(
            summary: ActiveRecordingSummary(id: id, deviceID: deviceID, deviceName: deviceName),
            sink: sink
        )
        return id
    }

    func sinks(for deviceID: String) -> [Sink] {
        entries.values.filter { $0.summary.deviceID == deviceID }.map(\.sink)
    }

    /// Removal closes frame admission synchronously, before async finalization.
    mutating func remove(id: UUID) -> Entry? { entries.removeValue(forKey: id) }

    mutating func remove(deviceID: String) -> [Entry] {
        let ids = summaries.filter { $0.deviceID == deviceID }.map(\.id)
        return ids.compactMap { entries.removeValue(forKey: $0) }
    }

    mutating func migrate(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        for id in Array(entries.keys) {
            guard let entry = entries[id], entry.summary.deviceID == oldID else { continue }
            entries[id]?.summary = ActiveRecordingSummary(
                id: id, deviceID: newID, deviceName: entry.summary.deviceName
            )
        }
    }
}
