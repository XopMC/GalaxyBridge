import Foundation

public enum ADBDeviceState: Equatable, Sendable {
    case device
    case offline
    case unauthorized
    case unknown(String)
}

public struct ADBDevice: Equatable, Sendable {
    public let serial: String
    public let state: ADBDeviceState
    public let model: String?
    public let product: String?
    public let device: String?
    public let transport: TransportKind

    public init(
        serial: String,
        state: ADBDeviceState,
        model: String?,
        product: String?,
        device: String?,
        transport: TransportKind
    ) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
        self.device = device
        self.transport = transport
    }
}

public enum ADBDeviceParser {
    public static func parse(_ output: String) -> [ADBDevice] {
        output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[0] != "List" else { return nil }
            let metadata = Dictionary(
                uniqueKeysWithValues: fields.dropFirst(2).compactMap { field -> (String, String)? in
                    guard let separator = field.firstIndex(of: ":") else { return nil }
                    return (
                        String(field[..<separator]),
                        String(field[field.index(after: separator)...])
                    )
                }
            )
            let serial = fields[0]
            return ADBDevice(
                serial: serial,
                state: state(fields[1]),
                model: metadata["model"],
                product: metadata["product"],
                device: metadata["device"],
                transport: serial.contains(":") || serial.contains("_adb-tls-connect._tcp") ? .wirelessADB : .usbADB
            )
        }
    }

    private static func state(_ value: String) -> ADBDeviceState {
        switch value {
        case "device": .device
        case "offline": .offline
        case "unauthorized": .unauthorized
        default: .unknown(value)
        }
    }
}
