import XCTest
@testable import StarmineCore

final class PlaybackCaptureNamingTests: XCTestCase {
    func testSanitizedFilenameComponentCollapsesWhitespaceAndPunctuation() {
        XCTAssertEqual(
            "S1E02 · The Test / Finale".sanitizedFilenameComponent(),
            "S1E02-The-Test-Finale"
        )
        XCTAssertEqual("   ".sanitizedFilenameComponent(), "item")
    }

    func testCaptureFilenameUsesLocalFileStemForPlainFiles() {
        let url = URL(fileURLWithPath: "/tmp/Frieren Episode 02.mkv")

        let filename = PlaybackCaptureNaming.filename(
            title: url.lastPathComponent,
            episodeLabel: "",
            collectionTitle: nil,
            assetURL: url,
            positionSeconds: 980,
            fileExtension: "png"
        )

        XCTAssertEqual(filename, "Frieren-Episode-02-00-16-20.png")
    }

    func testCaptureFilenameUsesCollectionAndEpisodeLabelForMetadataPlayback() {
        let filename = PlaybackCaptureNaming.filename(
            title: "葬送的芙莉莲",
            episodeLabel: "S2E03 · 大魔法使",
            collectionTitle: "葬送的芙莉莲",
            assetURL: URL(string: "https://example.com/Videos/12345"),
            positionSeconds: 3661,
            fileExtension: "png"
        )

        XCTAssertEqual(filename, "葬送的芙莉莲-S2E03-大魔法使-01-01-01.png")
    }

    func testCaptureTimestampPadsComponents() {
        XCTAssertEqual(PlaybackCaptureNaming.timestamp(for: 0), "00-00-00")
        XCTAssertEqual(PlaybackCaptureNaming.timestamp(for: 59.9), "00-00-59")
        XCTAssertEqual(PlaybackCaptureNaming.timestamp(for: 3_723), "01-02-03")
    }
}
