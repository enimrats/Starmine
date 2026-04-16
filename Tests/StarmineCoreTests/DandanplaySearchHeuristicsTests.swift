import XCTest
@testable import StarmineCore

final class DandanplaySearchHeuristicsTests: XCTestCase {
    func testCleanSearchKeywordStripsDecorationsAndEpisodeMarker() {
        let raw = "[VCB-Studio] 葬送的芙莉莲 - 第 12 话 [1080p]"
        XCTAssertEqual(DandanplaySearchHeuristics.cleanSearchKeyword(from: raw), "葬送的芙莉莲")
    }

    func testExtractEpisodeNumberIgnoresResolutionNoise() {
        let raw = "[VCB-Studio] Frieren EP03 1080p"
        XCTAssertEqual(DandanplaySearchHeuristics.extractEpisodeNumber(from: raw), 3)
    }

    func testExtractSeasonNumberHandlesExplicitAndSequelTitles() {
        XCTAssertEqual(DandanplaySearchHeuristics.extractSeasonNumber(from: "葬送的芙莉莲 第二季"), 2)
        XCTAssertEqual(DandanplaySearchHeuristics.extractSeasonNumber(from: "续 夏目友人帐"), 2)
        XCTAssertEqual(DandanplaySearchHeuristics.extractSeasonNumber(from: "夏目友人帐 参"), 3)
        XCTAssertEqual(DandanplaySearchHeuristics.extractSeasonNumber(from: "Frieren Season 2"), 2)
    }

    func testDecodeEncryptedAppSecretUsesExpectedTransformSequence() {
        XCTAssertEqual(DandanplayClient.decodeEncryptedAppSecret("Abc12Zzzz"), "YX98zaAAA")
    }
}
