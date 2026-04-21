import XCTest
@testable import StarmineCore

final class PlaybackModelsTests: XCTestCase {
    func testDetectsEAC3JOCSpatialAudioDecoder() {
        let track = MediaTrackOption(
            kind: .audio,
            mpvID: 1,
            title: "English Atmos",
            detail: "eng · eac3",
            isExternal: false,
            codec: "eac3",
            codecDescription: "Dolby Digital Plus",
            codecProfile: "JOC Atmos"
        )

        XCTAssertEqual(track.spatialAudioDecoder, .eac3joc)
        XCTAssertTrue(track.supportsSpatialAudio)
    }

    func testDetectsTrueHDAtmosSpatialAudioDecoder() {
        let track = MediaTrackOption(
            kind: .audio,
            mpvID: 2,
            title: "Dolby TrueHD Atmos 7.1",
            detail: "eng · truehd",
            isExternal: false,
            codec: "truehd",
            codecDescription: "TrueHD",
            codecProfile: nil
        )

        XCTAssertEqual(track.spatialAudioDecoder, .truehdatmos)
        XCTAssertTrue(track.supportsSpatialAudio)
    }

    func testDoesNotTreatPlainTrueHDAsSpatialAudio() {
        let track = MediaTrackOption(
            kind: .audio,
            mpvID: 3,
            title: "Dolby TrueHD 7.1",
            detail: "eng · truehd",
            isExternal: false,
            codec: "truehd",
            codecDescription: "TrueHD",
            codecProfile: nil
        )

        XCTAssertNil(track.spatialAudioDecoder)
        XCTAssertFalse(track.supportsSpatialAudio)
    }
}
