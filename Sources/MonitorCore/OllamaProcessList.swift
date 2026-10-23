import Foundation

public struct OllamaLoadedModel: Decodable, Equatable, Identifiable, Sendable {
    public let name: String
    public let size: Int64
    public let sizeVRAM: Int64
    public let contextLength: Int

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case sizeVRAM = "size_vram"
        case contextLength = "context_length"
    }
}

public struct OllamaProcessList: Decodable, Equatable {
    public let models: [OllamaLoadedModel]

    public init(models: [OllamaLoadedModel]) {
        self.models = models
    }
}

public enum OllamaProcessListState: Equatable {
    case unavailable
    case available([OllamaLoadedModel])

    public var models: [OllamaLoadedModel] {
        guard case let .available(models) = self else { return [] }
        return models
    }
}

public enum OllamaProcessListDecoder {
    public static func decode(statusCode: Int?, data: Data?, failed: Bool) -> OllamaProcessListState? {
        guard !failed, statusCode == 200, let data,
              let response = try? JSONDecoder().decode(OllamaProcessList.self, from: data) else {
            return nil
        }
        return .available(response.models)
    }
}

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
