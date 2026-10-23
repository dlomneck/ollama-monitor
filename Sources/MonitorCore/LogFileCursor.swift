public struct LogFileCursor {
    public private(set) var offset: UInt64 = 0
    public private(set) var identity: String?

    public init() {}

    public mutating func setInitialPosition(identity: String, size: UInt64) {
        self.identity = identity
        offset = size
    }

    @discardableResult
    public mutating func prepareRead(identity: String, size: UInt64) -> Bool {
        guard identity != self.identity || size < offset else { return false }
        self.identity = identity
        offset = 0
        return true
    }

    public mutating func advance(to size: UInt64) {
        offset = size
    }
}

public struct PollRequestGate {
    public private(set) var isInFlight = false

    public init() {}

    public mutating func begin() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    public mutating func finish() {
        isInFlight = false
    }
}
