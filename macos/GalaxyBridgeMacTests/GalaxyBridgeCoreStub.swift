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
