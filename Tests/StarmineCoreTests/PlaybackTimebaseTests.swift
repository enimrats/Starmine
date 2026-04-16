import XCTest
@testable import StarmineCore

final class PlaybackTimebaseTests: XCTestCase {
    func testResolvedPositionAdvancesWhilePlaying() {
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        let timebase = PlaybackTimebase(
            position: 12,
            duration: 100,
            paused: false,
            loaded: true,
            updatedAt: origin
        )

        XCTAssertEqual(timebase.resolvedPosition(at: origin.addingTimeInterval(0.75)), 12.75, accuracy: 0.001)
    }

    func testResolvedPositionStaysFixedWhenPaused() {
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        let timebase = PlaybackTimebase(
            position: 12,
            duration: 100,
            paused: true,
            loaded: true,
            updatedAt: origin
        )

        XCTAssertEqual(timebase.resolvedPosition(at: origin.addingTimeInterval(5)), 12, accuracy: 0.001)
    }

    func testResolvedPositionClampsToDuration() {
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        let timebase = PlaybackTimebase(
            position: 98.8,
            duration: 100,
            paused: false,
            loaded: true,
            updatedAt: origin
        )

        XCTAssertEqual(timebase.resolvedPosition(at: origin.addingTimeInterval(5)), 100, accuracy: 0.001)
    }

    func testReconciledTimebaseDoesNotRewindForMinorLaggingSnapshots() {
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        let previousSnapshot = PlaybackSnapshot(position: 12, duration: 100, paused: false, loaded: true, videoWidth: 1920, videoHeight: 1080)
        let previousTimebase = PlaybackTimebase(
            position: 12,
            duration: 100,
            paused: false,
            loaded: true,
            updatedAt: origin
        )
        let slightlyLaggingSnapshot = PlaybackSnapshot(position: 12.02, duration: 100, paused: false, loaded: true, videoWidth: 1920, videoHeight: 1080)
        let updateTime = origin.addingTimeInterval(0.033)

        let reconciled = PlaybackTimebase.reconciled(
            from: previousTimebase,
            previousSnapshot: previousSnapshot,
            snapshot: slightlyLaggingSnapshot,
            at: updateTime
        )

        XCTAssertEqual(reconciled.resolvedPosition(at: updateTime), 12.033, accuracy: 0.001)
    }

    func testReconciledTimebaseAcceptsLargeBackwardJumpAsSeek() {
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        let previousSnapshot = PlaybackSnapshot(position: 24, duration: 100, paused: false, loaded: true, videoWidth: 1920, videoHeight: 1080)
        let previousTimebase = PlaybackTimebase(
            position: 24,
            duration: 100,
            paused: false,
            loaded: true,
            updatedAt: origin
        )
        let seekedSnapshot = PlaybackSnapshot(position: 8, duration: 100, paused: false, loaded: true, videoWidth: 1920, videoHeight: 1080)
        let updateTime = origin.addingTimeInterval(0.033)

        let reconciled = PlaybackTimebase.reconciled(
            from: previousTimebase,
            previousSnapshot: previousSnapshot,
            snapshot: seekedSnapshot,
            at: updateTime
        )

        XCTAssertEqual(reconciled.resolvedPosition(at: updateTime), 8, accuracy: 0.001)
    }
}
