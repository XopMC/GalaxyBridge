import Foundation

private enum SpecFailure: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case let .missing(requirement): "missing scrcpy clipboard wiring: \(requirement)"
        }
    }
}

@main
private enum ScrcpyClipboardWiringSpec {
    static func main() throws {
        guard CommandLine.arguments.count == 5 else {
            fatalError("expected ScrcpySession.swift, AppModel.swift, ApplicationWindowSession.swift and ApplicationWindowCoordinator.swift paths")
        }
        let session = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let appModel = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let applicationSession = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
        let applicationCoordinator = try String(contentsOfFile: CommandLine.arguments[4], encoding: .utf8)

        try require(session, "ScrcpyControlReceivePipeline(", "v4.1 receive pipeline")
        try require(session, "case .ready:", "control ready state is handled")
        try require(session, "self?.receiveControl()", "receive loop starts when control is ready")
        try require(session, "receiveControl()", "control receive loop continues")
        try require(session, "clipboardEventHandler?(update)", "clipboard event is published")
        try require(session, "controlReceivePipeline.terminate", "socket close terminates receive once")

        try require(appModel, "session.clipboardEventHandler =", "AppModel subscribes before session start")
        try require(appModel, "acceptRemoteClipboard(", "enhanced and companion updates share one acceptance path")
        try require(appModel, "changeID: update.changeID", "enhanced clipboard receives a stable occurrence identity")
        try require(applicationSession, "scrcpy.clipboardEventHandler =", "independent app window subscribes to its scrcpy clipboard stream")
        try require(applicationSession, "clipboardEventHandler(update)", "independent app window forwards every clipboard occurrence")
        try require(applicationCoordinator, "acceptEnhancedClipboard(", "independent app window enters the selected-device clipboard acceptance path")
        print("PASS scrcpy control receive loop is wired into the shared AppModel clipboard pipeline")
    }

    private static func require(_ source: String, _ needle: String, _ requirement: String) throws {
        guard source.contains(needle) else { throw SpecFailure.missing(requirement) }
    }
}
