import Foundation

@main
enum DeviceSelectionResolverSpec {
    static func main() throws {
        let oldLAN = DeviceSelectionIdentity(
            id: "lan:bonjour-instance",
            adbSerial: nil,
            companionID: "bonjour-instance"
        )
        let pairedLAN = DeviceSelectionIdentity(
            id: "device:peer-uuid",
            adbSerial: nil,
            companionID: "bonjour-instance"
        )
        try expect(
            DeviceSelectionResolver.resolve(
                previousSelectionID: oldLAN.id,
                previousRows: [oldLAN],
                currentRows: [pairedLAN]
            ) == pairedLAN.id,
            "a selected Bonjour row must stay selected when pairing replaces its logical ID"
        )

        let oldADB = DeviceSelectionIdentity(id: "adb:serial", adbSerial: "serial", companionID: nil)
        let boundADB = DeviceSelectionIdentity(id: "device:bound", adbSerial: "serial", companionID: nil)
        try expect(
            DeviceSelectionResolver.resolve(
                previousSelectionID: oldADB.id,
                previousRows: [oldADB],
                currentRows: [boundADB]
            ) == boundADB.id,
            "an ADB row must stay selected after identity binding changes its logical ID"
        )

        let stable = DeviceSelectionIdentity(id: "device:stable", adbSerial: nil, companionID: "stable")
        try expect(
            DeviceSelectionResolver.resolve(
                previousSelectionID: stable.id,
                previousRows: [stable],
                currentRows: [stable]
            ) == stable.id,
            "a still-present selection must not change"
        )

        let fallback = DeviceSelectionIdentity(id: "device:fallback", adbSerial: nil, companionID: nil)
        try expect(
            DeviceSelectionResolver.resolve(
                previousSelectionID: "missing",
                previousRows: [],
                currentRows: [fallback]
            ) == fallback.id,
            "an invalid selection must never leave the UI pointing at a missing device"
        )

        try expect(
            DeviceSelectionResolver.resolve(
                previousSelectionID: "missing",
                previousRows: [],
                currentRows: []
            ) == nil,
            "selection must clear when no devices remain"
        )
        print("PASS selected device survives LAN pairing and ADB identity replacement")
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SelectionSpecFailure(message: message) }
}

private struct SelectionSpecFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
