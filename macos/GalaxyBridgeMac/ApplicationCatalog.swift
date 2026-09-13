import Foundation

struct ApplicationCatalogLoadKey: Hashable, Sendable {
    let deviceID: String
    let adbSerial: String?
}

struct ApplicationCatalogItem: Identifiable, Equatable, Sendable {
    let packageName: String
    let componentName: String?
    let label: String
    let iconPNG: Data?
    let isSystem: Bool

    var id: String { packageName }
}

enum ApplicationCatalogUnavailableReason: Equatable, Sendable {
    case directConnectionRequired
    case storeBuildUnsupported
}

enum ApplicationCatalogAccess: Equatable, Sendable {
    case available
    case unavailable(ApplicationCatalogUnavailableReason)
}

enum ApplicationCatalogState: Equatable, Sendable {
    case idle
    case loading
    case available([ApplicationCatalogItem])
    case unavailable(ApplicationCatalogUnavailableReason)
    case failed(String)
}

enum ApplicationCatalogPolicy {
    static func hasDirectTransport(adbSerial: String?) -> Bool {
        guard let adbSerial else { return false }
        return !adbSerial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func resolve(isStoreBuild: Bool, hasEnhancedTransport: Bool) -> ApplicationCatalogAccess {
        if isStoreBuild { return .unavailable(.storeBuildUnsupported) }
        if !hasEnhancedTransport { return .unavailable(.directConnectionRequired) }
        return .available
    }
}

enum EnhancedTextInputContext: Equatable, Sendable {
    case primaryDisplay
    case independentApplicationDisplay
}

enum EnhancedTextInputDestination: Equatable, Sendable {
    case companion
    case scrcpy
}

enum EnhancedTextInputDispatcher {
    @discardableResult
    static func send(
        _ text: String,
        context: EnhancedTextInputContext,
        companion: (String) -> Bool,
        scrcpy: (String) -> Void
    ) -> EnhancedTextInputDestination {
        // Accessibility can commit the complete Unicode string to the focused
        // editor, including an editor hosted by a scrcpy virtual display. The
        // Android bridge prioritizes that focused window ahead of the physical
        // display's active root. Keep scrcpy as the availability fallback.
        _ = context
        if companion(text) {
            return .companion
        }
        scrcpy(text)
        return .scrcpy
    }
}

enum EnhancedClipboardOperation: Equatable, Sendable {
    case copy
    case cut
}

enum EnhancedClipboardReadRequest: Equatable, Sendable {
    case readCurrent
    case atomicCopy
    case atomicCut
}

enum EnhancedClipboardRequestDestination: Equatable, Sendable {
    case companion
    case scrcpy
}

enum EnhancedClipboardRequestDispatcher {
    @discardableResult
    static func request(
        _ operation: EnhancedClipboardOperation,
        companion: (EnhancedClipboardOperation) -> Bool,
        scrcpy: (EnhancedClipboardReadRequest) -> Void
    ) -> EnhancedClipboardRequestDestination {
        if companion(operation) {
            scrcpy(.readCurrent)
            return .companion
        }
        scrcpy(operation == .cut ? .atomicCut : .atomicCopy)
        return .scrcpy
    }
}

enum EnhancedKeyInputDestination: Equatable, Sendable {
    case companion
    case scrcpy
}

enum EnhancedKeyInputDispatcher {
    @discardableResult
    static func send(
        isDown: Bool,
        keycode: UInt32,
        repeatCount: UInt32,
        modifiers: UInt32,
        companion: (Bool, UInt32, UInt32, UInt32) -> Bool,
        scrcpy: () -> Void
    ) -> EnhancedKeyInputDestination {
        if companion(isDown, keycode, repeatCount, modifiers) {
            return .companion
        }
        scrcpy()
        return .scrcpy
    }
}

enum ApplicationWindowPresentationPhase: Equatable, Sendable {
    case opening
    case controlReady
    case presenting
}

enum ApplicationWindowPresentationEvent: Equatable, Sendable {
    case controlReady
    case firstDecodedFrame
}

struct ApplicationWindowPresentationState: Equatable, Sendable {
    private(set) var phase: ApplicationWindowPresentationPhase = .opening

    var showsOpeningOverlay: Bool { phase != .presenting }

    mutating func handle(_ event: ApplicationWindowPresentationEvent) {
        switch event {
        case .controlReady:
            if phase == .opening { phase = .controlReady }
        case .firstDecodedFrame:
            // The video socket may deliver the virtual display's initial black
            // frame before the control socket is ready and START_APP is sent.
            // Only a frame decoded after control readiness can belong to the
            // requested application.
            if phase == .controlReady { phase = .presenting }
        }
    }

    mutating func reset() {
        phase = .opening
    }
}

struct ApplicationSessionLeaseRegistry: Sendable {
    let maximumApplicationWindows: Int
    private(set) var leasedSessionIDs: Set<String> = []

    init(maximumApplicationWindows: Int = SessionCapacityPolicy.maximumApplicationWindowSessions) {
        precondition(maximumApplicationWindows > 0)
        self.maximumApplicationWindows = maximumApplicationWindows
    }

    mutating func reserve(_ sessionID: String) -> Bool {
        if leasedSessionIDs.contains(sessionID) { return true }
        guard leasedSessionIDs.count < maximumApplicationWindows else { return false }
        leasedSessionIDs.insert(sessionID)
        return true
    }

    mutating func release(_ sessionID: String) {
        leasedSessionIDs.remove(sessionID)
    }
}

enum ApplicationWindowDiagnosticPolicy {
    static func afterReservation(
        reserved: Bool,
        currentDiagnostic: String?,
        limitDiagnostic: String
    ) -> String? {
        guard reserved else { return limitDiagnostic }
        return currentDiagnostic == limitDiagnostic ? nil : currentDiagnostic
    }

    static func afterRelease(
        currentDiagnostic: String?,
        limitDiagnostic: String
    ) -> String? {
        currentDiagnostic == limitDiagnostic ? nil : currentDiagnostic
    }
}
