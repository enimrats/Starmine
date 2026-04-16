import XCTest
@testable import StarmineCore

final class JellyfinModelsTests: XCTestCase {
    func testNormalizeURLAddsSchemeAndRemovesTrailingSlash() {
        XCTAssertEqual(JellyfinURLTools.normalize("example.com:8096///"), "http://example.com:8096")
    }

    func testEnabledRoutesPrioritizeLastSuccessfulRoute() {
        let primary = JellyfinRoute(name: "公网", url: "https://a.example.com", priority: 5)
        let fallback = JellyfinRoute(name: "内网", url: "http://10.0.0.2:8096", priority: 0)
        let account = JellyfinAccountProfile(
            serverID: "server",
            serverName: "Jellyfin",
            username: "alice",
            userID: "user",
            accessToken: "token",
            routes: [primary, fallback],
            lastSuccessfulRouteID: primary.id
        )

        XCTAssertEqual(account.enabledRoutes.first?.id, primary.id)
    }

    func testRouteRetryHonorsCooldownAfterRepeatedFailures() {
        let route = JellyfinRoute(
            name: "route",
            url: "http://example.com",
            lastFailureAt: Date(),
            failureCount: 3
        )
        XCTAssertFalse(route.shouldRetry())

        let cooledDown = JellyfinRoute(
            name: "route",
            url: "http://example.com",
            lastFailureAt: Date(timeIntervalSinceNow: -5),
            failureCount: 3
        )
        XCTAssertTrue(cooledDown.shouldRetry())
    }

    func testMediaItemMetaLineIncludesFormattedRating() {
        let item = JellyfinMediaItem(payload: [
            "Id": "1",
            "Name": "Frieren",
            "Type": "Series",
            "ProductionYear": 2024,
            "CommunityRating": 8.125,
        ])

        XCTAssertEqual(item.formattedCommunityRating, "8.12")
        XCTAssertEqual(item.metaLine, "剧集 · 2024 · 评分 8.12")
    }

    func testEpisodeDanmakuEpisodeOrdinalPrefersIndexNumber() {
        let episode = JellyfinEpisode(payload: [
            "Id": "ep-2",
            "Name": "Episode 2",
            "SeriesName": "Frieren",
            "SeriesId": "series-1",
            "SeasonId": "season-1",
            "ParentIndexNumber": 1,
            "IndexNumber": 2,
        ])

        XCTAssertEqual(episode.danmakuEpisodeOrdinal, 2)
    }

    func testEpisodeDanmakuEpisodeOrdinalFallsBackToTitleParsing() {
        let episode = JellyfinEpisode(payload: [
            "Id": "ep-12",
            "Name": "第 12 集",
            "SeriesName": "Frieren",
        ])

        XCTAssertEqual(episode.danmakuEpisodeOrdinal, 12)
    }
}
