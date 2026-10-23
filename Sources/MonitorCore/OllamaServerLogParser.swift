import Foundation

public enum OllamaLogLineKind: Equatable {
    case monitorPoll
    case promptProcessing
    case generationStart
    case generationTiming
    case stopped
    case idle
    case slotActivity
    case other
}

public enum OllamaServerLogParser {
    public static func classify(_ line: String) -> OllamaLogLineKind {
        let lower = line.lowercased()
        if lower.contains("get \"/api/ps\"") || lower.contains("get /api/ps") {
            return .monitorPoll
        }
        if lower.contains("prompt processing") { return .promptProcessing }
        if lower.contains("init_sampler") { return .generationStart }
        if lower.contains("tg =") || lower.contains("tg=") { return .generationTiming }
        if lower.contains("srv stop") || lower.contains("cancel task") || lower.contains("stop processing") {
            return .stopped
        }
        if lower.contains("all slots are idle") { return .idle }
        if lower.contains("slot operator") || lower.contains("slot update") || lower.contains("slot release") {
            return .slotActivity
        }
        return .other
    }

    public static func extractNumber(after marker: String, from line: String) -> Double? {
        guard let range = line.range(of: marker, options: .caseInsensitive) else { return nil }
        let remainder = line[range.upperBound...]
        guard let match = remainder.range(
            of: #"[-+]?[0-9]+(?:\.[0-9]+)?"#,
            options: .regularExpression
        ) else { return nil }
        return Double(remainder[match])
    }

    public static func extractSpeed(from line: String) -> Double? {
        if let range = line.range(of: #"tg\s*=\s*([0-9.]+)\s*t/s"#, options: .regularExpression) {
            let match = String(line[range])
            if let numberRange = match.range(of: #"[0-9.]+"#, options: .regularExpression) {
                return Double(match[numberRange])
            }
        }

        guard let range = line.range(
            of: "tokens per second",
            options: [.caseInsensitive, .backwards]
        ), let slash = line[..<range.lowerBound].lastIndex(of: "/") else {
            return nil
        }
        let value = line[line.index(after: slash)..<range.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        return Double(value)
    }
}
