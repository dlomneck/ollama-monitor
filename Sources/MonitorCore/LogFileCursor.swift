import Foundation

public enum LogFileCursorError: Error {
    case invalidUTF8
}

public struct LogFileCursor {
    public private(set) var offset: UInt64 = 0
    public private(set) var identity: String?
    private var pendingText = ""

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

    /// Reads appended bytes and advances only after UTF-8 decoding succeeds.
    /// Replacement and truncation restart the read at byte zero.
    public mutating func readAppendedText(at url: URL) throws -> String? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()

        _ = prepareRead(identity: identity, size: size)
        guard size > offset else { return nil }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        guard let text = String(data: data, encoding: .utf8) else {
            throw LogFileCursorError.invalidUTF8
        }
        advance(to: size)
        return text
    }

    /// Returns complete log lines while retaining a trailing partial line for the next read.
    public mutating func readAppendedLines(at url: URL) throws -> [String]? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileIdentity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if prepareRead(identity: fileIdentity, size: size) {
            pendingText = ""
        }
        guard size > offset else { return nil }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        guard let appended = String(data: data, encoding: .utf8) else {
            throw LogFileCursorError.invalidUTF8
        }
        advance(to: size)

        let chunks = (pendingText + appended).components(separatedBy: .newlines)
        pendingText = chunks.last ?? ""
        return Array(chunks.dropLast())
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
