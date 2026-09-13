import Foundation

public enum ScrcpyCodec: UInt32, Equatable, Sendable {
    case h264 = 0x6832_3634
    case h265 = 0x6832_3635
    case aac = 0x0061_6163
    case opus = 0x6F70_7573
    case raw = 0x0072_6177
}

public struct ScrcpyDisplay: Equatable, Sendable {
    public let id: UInt32
    public let width: UInt32?
    public let height: UInt32?

    public init(id: UInt32, width: UInt32?, height: UInt32?) {
        self.id = id
        self.width = width
        self.height = height
    }
}

public enum ScrcpyDisplayParser {
    public static func parse(_ output: String) -> [ScrcpyDisplay] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let marker = line.range(of: "--display-id=") else { return nil }
            let suffix = line[marker.upperBound...]
            let idText = suffix.prefix(while: \.isNumber)
            guard let id = UInt32(idText) else { return nil }
            guard let open = suffix.firstIndex(of: "("),
                  let close = suffix[open...].firstIndex(of: ")")
            else { return ScrcpyDisplay(id: id, width: nil, height: nil) }
            let size = suffix[suffix.index(after: open) ..< close].split(separator: "x", maxSplits: 1)
            guard size.count == 2, let width = UInt32(size[0]), let height = UInt32(size[1]) else {
                return ScrcpyDisplay(id: id, width: nil, height: nil)
            }
            return ScrcpyDisplay(id: id, width: width, height: height)
        }.sorted { $0.id < $1.id }
    }
}

public enum ScrcpyCaptureTarget: Equatable, Sendable {
    case display(id: UInt32)
    case virtualDisplay(width: UInt16, height: UInt16, dpi: UInt16?)
}

public enum ScrcpyStreamKind: Sendable {
    case video
    case audio
}

public struct ScrcpyVideoSession: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let clientResized: Bool

    public init(width: UInt32, height: UInt32, clientResized: Bool) {
        self.width = width
        self.height = height
        self.clientResized = clientResized
    }
}

public struct ScrcpyPacket: Equatable, Sendable {
    public let isConfiguration: Bool
    public let isKeyFrame: Bool
    public let presentationTimeUs: UInt64?
    public let payload: Data

    public init(
        isConfiguration: Bool,
        isKeyFrame: Bool,
        presentationTimeUs: UInt64?,
        payload: Data
    ) {
        self.isConfiguration = isConfiguration
        self.isKeyFrame = isKeyFrame
        self.presentationTimeUs = presentationTimeUs
        self.payload = payload
    }
}

public enum ScrcpyStreamEvent: Equatable, Sendable {
    case codec(ScrcpyCodec)
    case videoSession(ScrcpyVideoSession)
    case packet(ScrcpyPacket)
}

public enum ScrcpyStreamError: Error, Equatable {
    case unknownCodec(UInt32)
    case unexpectedSessionHeader
    case invalidSessionSize
    case invalidPacketLength(Int)
}

public struct ScrcpyStreamDecoder: Sendable {
    private static let sessionFlag: UInt64 = 1 << 63
    private static let configurationFlag: UInt64 = 1 << 62
    private static let keyFrameFlag: UInt64 = 1 << 61
    private static let presentationTimeMask: UInt64 = (1 << 61) - 1

    private let kind: ScrcpyStreamKind
    private let maxPayloadLength: Int
    private var buffer = Data()
    private var codec: ScrcpyCodec?
    private var receivedInitialVideoSession = false

    public var retainedStorageByteCount: Int { buffer.count }

    public init(kind: ScrcpyStreamKind, maxPayloadLength: Int) {
        precondition(maxPayloadLength > 0)
        self.kind = kind
        self.maxPayloadLength = maxPayloadLength
    }

    public mutating func append<S: DataProtocol>(_ bytes: S) throws -> [ScrcpyStreamEvent] {
        buffer.append(contentsOf: bytes)
        var events: [ScrcpyStreamEvent] = []
        var consumedStorage = false
        defer {
            if consumedStorage { compactStorage() }
        }
        if codec == nil {
            guard buffer.count >= 4 else { return [] }
            let raw = readUInt32(at: 0)
            guard let codec = ScrcpyCodec(rawValue: raw) else { throw ScrcpyStreamError.unknownCodec(raw) }
            self.codec = codec
            buffer.removeFirst(4)
            consumedStorage = true
            events.append(.codec(codec))
        }

        while buffer.count >= 12 {
            let header = readUInt64(at: 0)
            if header & Self.sessionFlag != 0 {
                guard kind == .video else { throw ScrcpyStreamError.unexpectedSessionHeader }
                let flags = readUInt32(at: 0)
                let width = readUInt32(at: 4)
                let height = readUInt32(at: 8)
                guard width > 0, height > 0 else { throw ScrcpyStreamError.invalidSessionSize }
                buffer.removeFirst(12)
                consumedStorage = true
                receivedInitialVideoSession = true
                events.append(.videoSession(.init(width: width, height: height, clientResized: flags & 1 != 0)))
                continue
            }
            if kind == .video && !receivedInitialVideoSession {
                throw ScrcpyStreamError.unexpectedSessionHeader
            }
            let length = Int(readUInt32(at: 8))
            guard length > 0, length <= maxPayloadLength else {
                throw ScrcpyStreamError.invalidPacketLength(length)
            }
            guard buffer.count >= 12 + length else { break }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 12)
            let payloadEnd = buffer.index(payloadStart, offsetBy: length)
            let payload = Data(buffer[payloadStart ..< payloadEnd])
            buffer.removeFirst(12 + length)
            consumedStorage = true
            let isConfiguration = header & Self.configurationFlag != 0
            let isKeyFrame = header & Self.keyFrameFlag != 0
            events.append(
                .packet(
                    .init(
                        isConfiguration: isConfiguration,
                        isKeyFrame: isKeyFrame,
                        presentationTimeUs: isConfiguration ? nil : header & Self.presentationTimeMask,
                        payload: payload
                    )
                )
            )
        }
        return events
    }

    private mutating func compactStorage() {
        if buffer.isEmpty {
            buffer = Data()
        } else {
            buffer = buffer.withUnsafeBytes { Data($0) }
        }
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        let start = buffer.index(buffer.startIndex, offsetBy: offset)
        let end = buffer.index(start, offsetBy: 4)
        return buffer[start ..< end].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func readUInt64(at offset: Int) -> UInt64 {
        let start = buffer.index(buffer.startIndex, offsetBy: offset)
        let end = buffer.index(start, offsetBy: 8)
        return buffer[start ..< end].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

public enum ScrcpyMotionAction: UInt8, Sendable {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
}

public enum ScrcpyKeyAction: UInt8, Sendable {
    case down = 0
    case up = 1
}

public struct ScrcpyUHIDGamepadButtons: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let south = Self(rawValue: 0x0001)
    public static let east = Self(rawValue: 0x0002)
    public static let west = Self(rawValue: 0x0008)
    public static let north = Self(rawValue: 0x0010)
    public static let leftShoulder = Self(rawValue: 0x0040)
    public static let rightShoulder = Self(rawValue: 0x0080)
    public static let back = Self(rawValue: 0x0400)
    public static let start = Self(rawValue: 0x0800)
    public static let guide = Self(rawValue: 0x1000)
    public static let leftStick = Self(rawValue: 0x2000)
    public static let rightStick = Self(rawValue: 0x4000)
}

public enum ScrcpyUHIDGamepadDPad: UInt8, Sendable {
    case neutral = 0
    case up = 1
    case upRight = 2
    case right = 3
    case downRight = 4
    case down = 5
    case downLeft = 6
    case left = 7
    case upLeft = 8
}

public struct ScrcpyUHIDGamepadReport: Equatable, Sendable {
    public static let vendorID: UInt16 = 0x045E
    public static let productID: UInt16 = 0x028E
    public static let deviceName = "Microsoft X-Box 360 Pad"

    // scrcpy 4.1 app/src/hid/hid_gamepad.c (SC_HID_GAMEPAD_REPORT_DESC).
    public static let reportDescriptor = Data([
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0xA1, 0x00,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x33,
        0x09, 0x34, 0x15, 0x00, 0x27, 0xFF, 0xFF, 0x00,
        0x00, 0x75, 0x10, 0x95, 0x04, 0x81, 0x02, 0x05,
        0x01, 0x09, 0x32, 0x09, 0x35, 0x15, 0x00, 0x26,
        0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x15, 0x00,
        0x25, 0x01, 0x95, 0x10, 0x75, 0x01, 0x81, 0x02,
        0x05, 0x01, 0x09, 0x39, 0x15, 0x01, 0x25, 0x08,
        0x75, 0x04, 0x95, 0x01, 0x81, 0x42, 0xC0, 0xC0,
    ])

    public let leftX: Double
    public let leftY: Double
    public let rightX: Double
    public let rightY: Double
    public let leftTrigger: Double
    public let rightTrigger: Double
    public let buttons: ScrcpyUHIDGamepadButtons
    public let dpad: ScrcpyUHIDGamepadDPad

    public init(
        leftX: Double = 0,
        leftY: Double = 0,
        rightX: Double = 0,
        rightY: Double = 0,
        leftTrigger: Double = 0,
        rightTrigger: Double = 0,
        buttons: ScrcpyUHIDGamepadButtons = [],
        dpad: ScrcpyUHIDGamepadDPad = .neutral
    ) {
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.buttons = buttons
        self.dpad = dpad
    }

    public var data: Data {
        var data = Data()
        data.appendLittleEndian(Self.axisValue(leftX))
        data.appendLittleEndian(Self.axisValue(leftY))
        data.appendLittleEndian(Self.axisValue(rightX))
        data.appendLittleEndian(Self.axisValue(rightY))
        data.appendLittleEndian(Self.triggerValue(leftTrigger))
        data.appendLittleEndian(Self.triggerValue(rightTrigger))
        data.appendLittleEndian(buttons.rawValue)
        data.append(dpad.rawValue)
        return data
    }

    private static func axisValue(_ value: Double) -> UInt16 {
        let normalized = value.isFinite ? value.clamped(to: -1 ... 1) : 0
        return UInt16((((normalized + 1) * 0.5) * Double(UInt16.max)).rounded())
    }

    private static func triggerValue(_ value: Double) -> UInt16 {
        let normalized = value.isFinite ? value.clamped(to: 0 ... 1) : 0
        return UInt16((normalized * Double(Int16.max)).rounded())
    }
}

/// The boot-protocol keyboard descriptor used by scrcpy 4.1's UHID keyboard.
///
/// Galaxy Bridge still commits composed/Unicode text through the scrcpy
/// clipboard channel. Creating this device makes Android correctly recognize
/// that the Mac provides a physical keyboard, so One UI can keep its software
/// keyboard out of the mirrored working area.
public enum ScrcpyUHIDKeyboard {
    public static let id: UInt16 = 1
    public static let deviceName = "Galaxy Bridge Keyboard"

    // Genymobile/scrcpy v4.1 app/src/hid/hid_keyboard.c
    public static let reportDescriptor = Data([
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7,
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
        0x95, 0x08, 0x81, 0x02, 0x75, 0x08,
        0x95, 0x01, 0x81, 0x01,
        0x05, 0x08, 0x19, 0x01, 0x29, 0x05,
        0x75, 0x01, 0x95, 0x05, 0x91, 0x02,
        0x75, 0x03, 0x95, 0x01, 0x91, 0x01,
        0x05, 0x07, 0x19, 0x00, 0x29, 0x65,
        0x15, 0x00, 0x25, 0x65, 0x75, 0x08,
        0x95, 0x06, 0x81, 0x00, 0xC0,
    ])

    public static var createMessage: Data {
        ScrcpyControlMessage.uhidCreate(
            id: id,
            vendorID: 0,
            productID: 0,
            name: deviceName,
            reportDescriptor: reportDescriptor
        )
    }

    /// Android accepts standard physical-keyboard Ctrl-V even when One UI's
    /// software keyboard is hidden. This is more reliable than KEYCODE_PASTE
    /// on Samsung firmware and keeps arbitrary UTF-8 content in the clipboard
    /// instead of trying to synthesize a lossy KeyCharacterMap sequence.
    public static var pasteMessages: [Data] {
        [
            ScrcpyControlMessage.uhidInput(
                id: id,
                report: Data([0x01, 0x00, 0x19, 0x00, 0x00, 0x00, 0x00, 0x00])
            ),
            ScrcpyControlMessage.uhidInput(
                id: id,
                report: Data(repeating: 0, count: 8)
            ),
        ]
    }
}

public enum ScrcpyControlMessage {
    /// scrcpy's reserved synthetic-touch contacts. These must not be sent as
    /// the reserved mouse pointer (`UInt64.max`), because Android then expects
    /// mouse button semantics instead of a touchscreen gesture.
    public static let virtualFingerPointerID = UInt64.max - 1
    public static let virtualSecondFingerPointerID = UInt64.max - 2

    public static func keycode(
        action: ScrcpyKeyAction,
        androidKeycode: UInt32,
        repeatCount: UInt32 = 0,
        metaState: UInt32 = 0
    ) -> Data {
        var data = Data([0, action.rawValue])
        data.appendBigEndian(androidKeycode)
        data.appendBigEndian(repeatCount)
        data.appendBigEndian(metaState)
        return data
    }

    public static func text(_ text: String) -> Data {
        let content = utf8Prefix(text, maximumLength: 300)
        var data = Data([1])
        data.appendBigEndian(UInt32(content.count))
        data.append(content)
        return data
    }

    public static func touch(
        action: ScrcpyMotionAction,
        pointerID: UInt64,
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        pressure: Double,
        actionButton: UInt32,
        buttons: UInt32
    ) -> Data {
        var data = Data([2, action.rawValue])
        data.appendBigEndian(pointerID)
        data.appendBigEndian(UInt32(bitPattern: x))
        data.appendBigEndian(UInt32(bitPattern: y))
        data.appendBigEndian(screenWidth)
        data.appendBigEndian(screenHeight)
        let pressureValue = UInt16((pressure.isFinite ? pressure.clamped(to: 0 ... 1) : 0) * Double(UInt16.max))
        data.appendBigEndian(pressureValue)
        data.appendBigEndian(actionButton)
        data.appendBigEndian(buttons)
        return data
    }

    public static func virtualFingerTouch(
        action: ScrcpyMotionAction,
        pointerID: UInt64 = virtualFingerPointerID,
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        pressure: Double
    ) -> Data {
        touch(
            action: action,
            pointerID: pointerID,
            x: x,
            y: y,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            pressure: pressure,
            actionButton: 0,
            buttons: 0
        )
    }

    public static func scroll(
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        horizontal: Double,
        vertical: Double,
        buttons: UInt32 = 0
    ) -> Data {
        var data = Data([3])
        data.appendBigEndian(UInt32(bitPattern: x))
        data.appendBigEndian(UInt32(bitPattern: y))
        data.appendBigEndian(screenWidth)
        data.appendBigEndian(screenHeight)
        data.appendBigEndian(scrollFixedPoint(horizontal))
        data.appendBigEndian(scrollFixedPoint(vertical))
        data.appendBigEndian(buttons)
        return data
    }

    public static func injectTextMessages(
        _ text: String,
        maximumPayloadLength: Int = 300
    ) -> [Data] {
        let limit = max(1, min(maximumPayloadLength, Int(UInt32.max)))
        var chunks: [Data] = []
        var current = Data()

        for character in text {
            let encoded = Data(String(character).utf8)
            if !current.isEmpty, current.count + encoded.count > limit {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
            if encoded.count > limit {
                chunks.append(encoded)
            } else {
                current.append(encoded)
            }
        }
        if !current.isEmpty { chunks.append(current) }

        return chunks.map { content in
            var data = Data([1])
            data.appendBigEndian(UInt32(content.count))
            data.append(content)
            return data
        }
    }

    public static func setClipboard(sequence: UInt64, text: String, paste: Bool) -> Data {
        let content = utf8Prefix(text, maximumLength: (1 << 18) - 14)
        var data = Data([9])
        data.appendBigEndian(sequence)
        data.append(paste ? 1 : 0)
        data.appendBigEndian(UInt32(content.count))
        data.append(content)
        return data
    }

    public enum ClipboardCopyKey: UInt8, Sendable {
        case none = 0
        case copy = 1
        case cut = 2
    }

    /// Requests the device clipboard through scrcpy's bidirectional control
    /// channel. The copy/cut variants first inject the corresponding Android
    /// key and wait for it to finish, so the returned DeviceMessage contains
    /// the selection that was active when the Mac shortcut was pressed.
    public static func getClipboard(copyKey: ClipboardCopyKey = .none) -> Data {
        Data([8, copyKey.rawValue])
    }

    /// Copy/cut and clipboard retrieval must be one server-side operation.
    /// scrcpy injects the requested key with WAIT_FOR_FINISH before reading
    /// Android's clipboard, avoiding a race with editors on virtual displays.
    public static func clipboardRequestMessages(copyKey: ClipboardCopyKey) -> [Data] {
        [getClipboard(copyKey: copyKey)]
    }

    /// Samsung Chrome and several One UI editors handle the standard Ctrl
    /// chord more reliably than KEYCODE_COPY/KEYCODE_CUT on virtual displays.
    /// The caller reads the clipboard back only after these two messages have
    /// been processed.
    public static func clipboardShortcutKeyMessages(copyKey: ClipboardCopyKey) -> [Data] {
        let androidKeycode: UInt32
        switch copyKey {
        case .copy: androidKeycode = 31 // KEYCODE_C
        case .cut: androidKeycode = 52 // KEYCODE_X
        case .none: return []
        }
        let controlMeta: UInt32 = 0x1000 | 0x2000
        return [
            keycode(action: .down, androidKeycode: androidKeycode, metaState: controlMeta),
            keycode(action: .up, androidKeycode: androidKeycode, metaState: controlMeta),
        ]
    }

    /// A standard Ctrl-V pair sent through scrcpy's keycode injector. Unlike
    /// Android's synthetic KEYCODE_PASTE, this is handled by Samsung Chrome
    /// and is addressed to this scrcpy session's action display.
    public static var clipboardPasteKeyMessages: [Data] {
        let controlMeta: UInt32 = 0x1000 | 0x2000
        return [
            keycode(action: .down, androidKeycode: 50, metaState: controlMeta), // KEYCODE_V
            keycode(action: .up, androidKeycode: 50, metaState: controlMeta),
        ]
    }

    public static func setDisplayPower(on: Bool) -> Data { Data([10, on ? 1 : 0]) }
    public static var rotateDevice: Data { Data([11]) }

    public static func uhidCreate(
        id: UInt16,
        vendorID: UInt16,
        productID: UInt16,
        name: String,
        reportDescriptor: Data
    ) -> Data {
        precondition(reportDescriptor.count <= Int(UInt16.max))
        let encodedName = utf8Prefix(name, maximumLength: 127)
        var data = Data([12])
        data.appendBigEndian(id)
        data.appendBigEndian(vendorID)
        data.appendBigEndian(productID)
        data.append(UInt8(encodedName.count))
        data.append(encodedName)
        data.appendBigEndian(UInt16(reportDescriptor.count))
        data.append(reportDescriptor)
        return data
    }

    public static func uhidInput(id: UInt16, report: Data) -> Data {
        precondition(report.count <= Int(UInt16.max))
        var data = Data([13])
        data.appendBigEndian(id)
        data.appendBigEndian(UInt16(report.count))
        data.append(report)
        return data
    }

    public static func uhidDestroy(id: UInt16) -> Data {
        var data = Data([14])
        data.appendBigEndian(id)
        return data
    }

    /// scrcpy 4.1 starts an application through control message type 16.
    /// This is intentionally not a server launch option: the virtual display
    /// id only exists after the capture/control channels have connected.
    public static func startApp(_ name: String) -> Data {
        let content = utf8Prefix(name, maximumLength: 255)
        var data = Data([16, UInt8(content.count)])
        data.append(content)
        return data
    }

    /// scrcpy 4.1 TYPE_RESIZE_DISPLAY: u8 type, then unsigned u16 width and
    /// height in network byte order. This is valid only for flex displays;
    /// callers own that launch-policy decision.
    public static func resizeDisplay(width: UInt16, height: UInt16) -> Data {
        precondition(width > 0 && height > 0)
        var data = Data([21])
        data.appendBigEndian(width)
        data.appendBigEndian(height)
        return data
    }

    fileprivate static func utf8Prefix(_ value: String, maximumLength: Int) -> Data {
        var result = Data()
        for scalar in value.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if result.count + bytes.count > maximumLength { break }
            result.append(bytes)
        }
        return result
    }

    private static func scrollFixedPoint(_ value: Double) -> Int16 {
        let normalized = (value.isFinite ? value : 0).clamped(to: -16 ... 16) / 16
        let scaled = Int32(normalized * 32_768)
        return Int16(clamping: scaled)
    }
}

public enum ScrcpyKeyboardPasteMode: Equatable, Sendable {
    /// Replace the clipboard, wait for its acknowledgement, then send a UHID Ctrl-V chord.
    case acknowledgedUHID
    /// Replace the clipboard, wait for its acknowledgement, then inject a
    /// session-targeted Ctrl-V keycode pair for an independent display.
    case acknowledgedDisplayKeycode
    /// Let the scrcpy server inject KEYCODE_PASTE on the session's own target display.
    case serverTargeted
}

public struct ScrcpyTextInputPlan: Equatable, Sendable {
    public let controlMessage: Data
    public let clipboardEcho: Data?

    public static func make(
        text: String,
        clipboardSequence: UInt64,
        pasteMode: ScrcpyKeyboardPasteMode = .acknowledgedUHID
    ) -> Self {
        let content = ScrcpyControlMessage.utf8Prefix(text, maximumLength: (1 << 18) - 14)
        let boundedText = String(decoding: content, as: UTF8.self)
        return Self(
            controlMessage: ScrcpyControlMessage.setClipboard(
                sequence: clipboardSequence,
                text: boundedText,
                paste: pasteMode == .serverTargeted
            ),
            clipboardEcho: content
        )
    }
}

public enum ScrcpyTextInputRoute: Equatable, Sendable {
    case directInjection
    case clipboardPaste
}

/// Samsung's KeyCharacterMap may silently drop otherwise-valid ASCII letters
/// delivered through scrcpy's SDK text event, especially on a virtual display.
/// Use the acknowledged clipboard-paste transaction for all committed text.
/// DeviceInputNSView batches adjacent physical keystrokes and
/// ScrcpyKeyboardInputQueue serializes each transaction until its acknowledgement,
/// so this stays lossless without overlapping asynchronous paste operations.
public enum ScrcpyTextInputRoutingPolicy {
    public static func route(for text: String) -> ScrcpyTextInputRoute {
        _ = text
        return .clipboardPaste
    }
}

public struct ScrcpyKeyboardEmission: Equatable, Sendable {
    public let controlMessage: Data
    public let clipboardEcho: Data?
    public let clipboardSequence: UInt64?

    public init(
        controlMessage: Data,
        clipboardEcho: Data?,
        clipboardSequence: UInt64? = nil
    ) {
        self.controlMessage = controlMessage
        self.clipboardEcho = clipboardEcho
        self.clipboardSequence = clipboardSequence
    }
}

public struct ScrcpyKeyboardSettlementTicket: Equatable, Sendable {
    public let clipboardSequence: UInt64
    public let revision: UInt64

    public init(clipboardSequence: UInt64, revision: UInt64) {
        self.clipboardSequence = clipboardSequence
        self.revision = revision
    }
}

public struct ScrcpyKeyboardInputQueue: Sendable {
    private enum Pending: Sendable {
        case text(String, ScrcpyKeyboardPasteMode)
        case control(Data)
    }

    private var pending: [Pending] = []
    private var inFlightClipboardSequence: UInt64?
    private var inFlightPasteMode: ScrcpyKeyboardPasteMode?
    private var settlingClipboardSequence: UInt64?
    private var settlementRevision: UInt64 = 0
    private var nextClipboardSequence: UInt64

    public init(initialClipboardSequence: UInt64 = 0x8000_0000_0000_0000) {
        nextClipboardSequence = initialClipboardSequence
    }

    public mutating func enqueueText(
        _ text: String,
        pasteMode: ScrcpyKeyboardPasteMode = .acknowledgedUHID
    ) -> [ScrcpyKeyboardEmission] {
        guard !text.isEmpty else { return [] }
        if settlingClipboardSequence != nil {
            settlementRevision &+= 1
        }
        if let last = pending.indices.last,
           case let .text(existing, existingMode) = pending[last],
           existingMode == pasteMode {
            pending[last] = .text(existing + text, pasteMode)
        } else {
            pending.append(.text(text, pasteMode))
        }
        return drain()
    }

    public mutating func enqueueControl(_ controlMessage: Data) -> [ScrcpyKeyboardEmission] {
        guard !controlMessage.isEmpty else { return [] }
        pending.append(.control(controlMessage))
        return drain()
    }

    public mutating func acknowledgeClipboard(sequence: UInt64) -> [ScrcpyKeyboardEmission] {
        guard inFlightClipboardSequence == sequence else { return [] }
        let pasteMode = inFlightPasteMode
        inFlightClipboardSequence = nil
        inFlightPasteMode = nil
        settlingClipboardSequence = sequence
        settlementRevision &+= 1
        switch pasteMode {
        case .acknowledgedUHID:
            return ScrcpyUHIDKeyboard.pasteMessages.map {
                ScrcpyKeyboardEmission(controlMessage: $0, clipboardEcho: nil)
            }
        case .acknowledgedDisplayKeycode:
            return ScrcpyControlMessage.clipboardPasteKeyMessages.map {
                ScrcpyKeyboardEmission(controlMessage: $0, clipboardEcho: nil)
            }
        case .serverTargeted:
            return []
        case nil:
            return []
        }
    }

    public var clipboardSettlementTicket: ScrcpyKeyboardSettlementTicket? {
        settlingClipboardSequence.map {
            ScrcpyKeyboardSettlementTicket(clipboardSequence: $0, revision: settlementRevision)
        }
    }

    public func isSettlingClipboard(sequence: UInt64) -> Bool {
        settlingClipboardSequence == sequence
    }

    public mutating func completeClipboardSettlement(
        ticket: ScrcpyKeyboardSettlementTicket
    ) -> [ScrcpyKeyboardEmission] {
        guard clipboardSettlementTicket == ticket else { return [] }
        settlingClipboardSequence = nil
        return drain()
    }

    public mutating func completeClipboardSettlement(sequence: UInt64) -> [ScrcpyKeyboardEmission] {
        guard let ticket = clipboardSettlementTicket,
              ticket.clipboardSequence == sequence
        else { return [] }
        return completeClipboardSettlement(ticket: ticket)
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        inFlightClipboardSequence = nil
        inFlightPasteMode = nil
        settlingClipboardSequence = nil
        settlementRevision &+= 1
    }

    private mutating func drain() -> [ScrcpyKeyboardEmission] {
        guard inFlightClipboardSequence == nil, settlingClipboardSequence == nil else { return [] }
        var emissions: [ScrcpyKeyboardEmission] = []
        while !pending.isEmpty {
            switch pending.removeFirst() {
            case let .control(controlMessage):
                emissions.append(ScrcpyKeyboardEmission(controlMessage: controlMessage, clipboardEcho: nil))
            case let .text(text, pasteMode):
                let sequence = nextClipboardSequence
                nextClipboardSequence &+= 1
                let plan = ScrcpyTextInputPlan.make(
                    text: text,
                    clipboardSequence: sequence,
                    pasteMode: pasteMode
                )
                inFlightClipboardSequence = sequence
                inFlightPasteMode = pasteMode
                emissions.append(
                    ScrcpyKeyboardEmission(
                        controlMessage: plan.controlMessage,
                        clipboardEcho: plan.clipboardEcho,
                        clipboardSequence: sequence
                    )
                )
                return emissions
            }
        }
        return emissions
    }
}

public struct ScrcpyInjectedClipboardEchoSuppressor: Sendable {
    private let capacity: Int
    private var pending: [Data] = []

    public init(capacity: Int = 8) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func markInjected(_ content: Data) {
        guard !content.isEmpty else { return }
        pending.append(content)
        if pending.count > capacity {
            pending.removeFirst(pending.count - capacity)
        }
    }

    public mutating func shouldForward(_ content: Data) -> Bool {
        guard let index = pending.firstIndex(of: content) else { return true }
        pending.remove(at: index)
        return false
    }

    /// Releases an expected echo once scrcpy has acknowledged and settled the
    /// computer-originated clipboard write. Some Android builds acknowledge
    /// SET_CLIPBOARD without reflecting a DEVICE_CLIPBOARD message; keeping the
    /// expectation forever would swallow the user's next intentional copy of
    /// the same text.
    public mutating func discardInjected(_ content: Data) {
        guard let index = pending.firstIndex(of: content) else { return }
        pending.remove(at: index)
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
