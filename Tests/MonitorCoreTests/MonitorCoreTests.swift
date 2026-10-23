import Testing
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
}
