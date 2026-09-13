import Foundation

struct DeviceSelectionIdentity: Equatable, Sendable {
    let id: String
    let adbSerial: String?
    let companionID: String?
}

enum DeviceSelectionResolver {
    static func resolve(
        previousSelectionID: String?,
        previousRows: [DeviceSelectionIdentity],
        currentRows: [DeviceSelectionIdentity]
    ) -> String? {
        guard !currentRows.isEmpty else { return nil }
        guard let previousSelectionID else { return currentRows.first?.id }
        if currentRows.contains(where: { $0.id == previousSelectionID }) {
            return previousSelectionID
        }
        guard let previous = previousRows.first(where: { $0.id == previousSelectionID }) else {
            return currentRows.first?.id
        }
        if let serial = previous.adbSerial,
           let replacement = currentRows.first(where: { $0.adbSerial == serial }) {
            return replacement.id
        }
        if let companionID = previous.companionID,
           let replacement = currentRows.first(where: { $0.companionID == companionID }) {
            return replacement.id
        }
        return currentRows.first?.id
    }
}
