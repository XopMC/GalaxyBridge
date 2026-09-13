public struct DisplayDescriptor: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rotationDegrees: Int
    public let displayID: UInt32

    public init(width: Int, height: Int, rotationDegrees: Int, displayID: UInt32) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        self.rotationDegrees = rotationDegrees
        self.displayID = displayID
    }
}

public struct DisplayEpochTracker: Sendable {
    public private(set) var epoch: UInt32 = 0
    private var descriptor: DisplayDescriptor?

    public init() {}

    public mutating func observe(_ nextDescriptor: DisplayDescriptor) -> UInt32 {
        if nextDescriptor != descriptor {
            descriptor = nextDescriptor
            epoch &+= 1
        }
        return epoch
    }
}
