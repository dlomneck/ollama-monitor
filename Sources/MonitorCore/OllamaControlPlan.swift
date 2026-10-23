import Foundation

public enum OllamaControlAction: Equatable {
    case start
    case stop
    case restart
}

public enum OllamaControlStep: Equatable {
    case stop
    case confirmOffline
    case pauseBeforeLaunch
    case launch
    case confirmOnline
}

public enum OllamaControlPlan {
    public static func steps(for action: OllamaControlAction) -> [OllamaControlStep] {
        switch action {
        case .start: return [.launch, .confirmOnline]
        case .stop: return [.stop, .confirmOffline]
        case .restart: return [.stop, .confirmOffline, .pauseBeforeLaunch, .launch, .confirmOnline]
        }
    }

    public static func execute(
        _ steps: [OllamaControlStep],
        operation: (OllamaControlStep) throws -> Void
    ) rethrows {
        for step in steps { try operation(step) }
    }
}

public struct PollRequestGeneration: Equatable {
    private var current = UUID()

    public init() {}

    @discardableResult
    public mutating func advance() -> UUID {
        current = UUID()
        return current
    }

    public mutating func invalidate() {
        current = UUID()
    }

    public func accepts(_ token: UUID) -> Bool {
        current == token
    }
}
