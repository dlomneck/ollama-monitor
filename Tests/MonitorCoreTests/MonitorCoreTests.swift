import Testing
import Foundation
@testable import MonitorCore

@Suite
struct MonitorCoreTests {
    @Test func logCursorContinuesAtSavedOffsetForSameFile() {
        var cursor = LogFileCursor()
        cursor.setInitialPosition(identity: "file-a", size: 120)

        let didReset = cursor.prepareRead(identity: "file-a", size: 180)
        #expect(!didReset)
        #expect(cursor.offset == 120)
    }

    @Test func logCursorResetsWhenFileIsReplaced() {
        var cursor = LogFileCursor()
        cursor.setInitialPosition(identity: "file-a", size: 120)

        let didReset = cursor.prepareRead(identity: "file-b", size: 130)
        #expect(didReset)
        #expect(cursor.offset == 0)
    }

    @Test func logCursorResetsWhenFileIsTruncated() {
        var cursor = LogFileCursor()
        cursor.setInitialPosition(identity: "file-a", size: 120)

        let didReset = cursor.prepareRead(identity: "file-a", size: 40)
        #expect(didReset)
        #expect(cursor.offset == 0)
    }

    @Test func logCursorDoesNotAdvanceUntilReadSucceeds() {
        var cursor = LogFileCursor()
        cursor.setInitialPosition(identity: "file-a", size: 120)

        _ = cursor.prepareRead(identity: "file-a", size: 180)
        // A failed seek, read, or decode leaves the cursor unchanged.
        #expect(cursor.offset == 120)

        cursor.advance(to: 180)
        #expect(cursor.offset == 180)
    }

    @Test func pollRequestGatePreventsOverlapAndCanRecover() {
        var gate = PollRequestGate()

        let firstRequestStarted = gate.begin()
        let overlappingRequestStarted = gate.begin()
        #expect(firstRequestStarted)
        #expect(!overlappingRequestStarted)
        #expect(gate.isInFlight)

        gate.finish()
        #expect(!gate.isInFlight)
        let recoveryRequestStarted = gate.begin()
        #expect(recoveryRequestStarted)
    }

    @Test func processListDecodesMultipleModelsAndEmptyList() throws {
        let data = Data(#"{"models":[{"name":"alpha","size":1000,"size_vram":800,"context_length":4096},{"name":"beta","size":2000,"size_vram":0,"context_length":2048}]}"#.utf8)
        let state = OllamaProcessListDecoder.decode(statusCode: 200, data: data, failed: false)
        #expect(state?.models.map(\.name) == ["alpha", "beta"])
        #expect(state?.models.first?.sizeVRAM == 800)

        let empty = OllamaProcessListDecoder.decode(
            statusCode: 200,
            data: Data(#"{"models":[]}"#.utf8),
            failed: false
        )
        #expect(empty == .available([]))
    }

    @Test func processListRejectsFailuresHTTPAndMalformedJSON() {
        let valid = Data(#"{"models":[]}"#.utf8)
        #expect(OllamaProcessListDecoder.decode(statusCode: 503, data: valid, failed: false) == nil)
        #expect(OllamaProcessListDecoder.decode(statusCode: 200, data: valid, failed: true) == nil)
        #expect(OllamaProcessListDecoder.decode(statusCode: 200, data: Data("{".utf8), failed: false) == nil)
    }

    @Test func fileCursorReadsAppendsAndRetriesInvalidUTF8WithoutAdvancing() throws {
        let url = try temporaryLog(contents: "first")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var cursor = LogFileCursor()

        #expect(try cursor.readAppendedText(at: url) == "first")
        #expect(cursor.offset == 5)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\nnext".utf8))
        try handle.close()
        #expect(try cursor.readAppendedText(at: url) == "\nnext")

        let invalid = try FileHandle(forWritingTo: url)
        try invalid.seekToEnd()
        try invalid.write(contentsOf: Data([0xFF]))
        try invalid.close()
        let savedOffset = cursor.offset
        #expect(throws: LogFileCursorError.self) { try cursor.readAppendedText(at: url) }
        #expect(cursor.offset == savedOffset)
    }

    @Test func fileCursorReadsFromStartAfterTruncationAndReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("server.log")
        try Data("long contents".utf8).write(to: url)
        var cursor = LogFileCursor()
        #expect(try cursor.readAppendedText(at: url) == "long contents")

        try Data("new".utf8).write(to: url)
        #expect(try cursor.readAppendedText(at: url) == "new")

        try FileManager.default.removeItem(at: url)
        try Data("replacement".utf8).write(to: url)
        #expect(try cursor.readAppendedText(at: url) == "replacement")
    }

    @Test func lineReaderKeepsPartialLineUntilNewlineArrives() throws {
        let url = try temporaryLog(contents: "first")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var cursor = LogFileCursor()

        #expect(try cursor.readAppendedLines(at: url) == [])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" line\nsecond\n".utf8))
        try handle.close()

        #expect(try cursor.readAppendedLines(at: url) == ["first line", "second"])
    }

    @Test func controlPlansUseExpectedOrderAndStopAfterFailure() throws {
        #expect(OllamaControlPlan.steps(for: .start) == [.launch, .confirmOnline])
        #expect(OllamaControlPlan.steps(for: .stop) == [.stop, .confirmOffline])
        #expect(OllamaControlPlan.steps(for: .restart) == [
            .stop, .confirmOffline, .pauseBeforeLaunch, .launch, .confirmOnline
        ])

        enum ExpectedFailure: Error { case launchFailed }
        var executed: [OllamaControlStep] = []
        #expect(throws: ExpectedFailure.self) {
            try OllamaControlPlan.execute(OllamaControlPlan.steps(for: .restart)) { step in
                executed.append(step)
                if step == .launch { throw ExpectedFailure.launchFailed }
            }
        }
        #expect(executed == [.stop, .confirmOffline, .pauseBeforeLaunch, .launch])
    }

    private func temporaryLog(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("server.log")
        try Data(contents.utf8).write(to: url)
        return url
    }
}
