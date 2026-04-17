import XCTest
@testable import StarmineCore

actor MockDandanplayClient: DandanplayClientProtocol {
    let searchResults: [AnimeSearchResult]
    let episodesByAnimeID: [Int: [AnimeEpisode]]
    let commentsByEpisodeID: [Int: [DanmakuComment]]
    private(set) var searchedKeywords: [String] = []

    init(
        searchResults: [AnimeSearchResult] = [],
        episodesByAnimeID: [Int: [AnimeEpisode]] = [:],
        commentsByEpisodeID: [Int: [DanmakuComment]] = [:]
    ) {
        self.searchResults = searchResults
        self.episodesByAnimeID = episodesByAnimeID
        self.commentsByEpisodeID = commentsByEpisodeID
    }

    func searchAnime(keyword: String) async throws -> [AnimeSearchResult] {
        searchedKeywords.append(keyword)
        return searchResults
    }

    func loadEpisodes(for animeID: Int) async throws -> [AnimeEpisode] {
        episodesByAnimeID[animeID] ?? []
    }

    func loadDanmaku(episodeID: Int, chConvert: Int) async throws -> [DanmakuComment] {
        commentsByEpisodeID[episodeID] ?? []
    }

    func searchCallCount() -> Int {
        searchedKeywords.count
    }
}

@MainActor
final class DanmakuFeatureStoreTests: XCTestCase {
    func testSearchAndAutoloadSelectsInferredEpisode() async throws {
        let client = MockDandanplayClient(
            searchResults: [
                AnimeSearchResult(id: 100, title: "Frieren", typeDescription: "TV", imageURL: nil, episodeCount: 28),
            ],
            episodesByAnimeID: [
                100: [
                    AnimeEpisode(id: 1, number: 1, title: "旅立ち"),
                    AnimeEpisode(id: 2, number: 2, title: "魔法使い"),
                ],
            ],
            commentsByEpisodeID: [
                2: [DanmakuComment(time: 1.0, text: "picked", presentation: .scroll, color: .white)],
            ]
        )

        let store = DanmakuFeatureStore(client: client)
        store.prepareSearch(query: "Frieren", inferredSeasonNumber: nil, inferredEpisodeNumber: 2)

        let episode = try await store.searchAndAutoloadDanmaku()

        XCTAssertEqual(store.selectedAnimeID, 100)
        XCTAssertEqual(store.selectedEpisodeID, 2)
        XCTAssertEqual(episode?.id, 2)

        store.renderer.sync(playbackTime: 1.0, viewportSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(store.renderer.activeItems.map(\.comment.text), ["picked"])
    }

    func testEmptyQueryClearsResultsAndEpisodes() async throws {
        let store = DanmakuFeatureStore(client: MockDandanplayClient())
        store.searchResults = [AnimeSearchResult(id: 1, title: "old", typeDescription: "", imageURL: nil, episodeCount: nil)]
        store.episodes = [AnimeEpisode(id: 1, number: 1, title: "old ep")]
        store.searchQuery = "   "

        let episode = try await store.searchAndAutoloadDanmaku()

        XCTAssertNil(episode)
        XCTAssertTrue(store.searchResults.isEmpty)
        XCTAssertTrue(store.episodes.isEmpty)
        XCTAssertNil(store.selectedAnimeID)
    }

    func testPickEpisodeReloadsDanmakuForSelection() async throws {
        let client = MockDandanplayClient(
            commentsByEpisodeID: [
                7: [DanmakuComment(time: 0.5, text: "episode 7", presentation: .top, color: .white)],
            ]
        )

        let store = DanmakuFeatureStore(client: client)
        let episode = AnimeEpisode(id: 7, number: 7, title: "继续前进")

        try await store.pickEpisode(episode)

        XCTAssertEqual(store.selectedEpisodeID, 7)
        store.renderer.sync(playbackTime: 1.0, viewportSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(store.renderer.activeItems.map(\.comment.text), ["episode 7"])
    }

    func testSearchAndAutoloadMatchesSeasonThenSelectsEpisodeByOrdinal() async throws {
        let client = MockDandanplayClient(
            searchResults: [
                AnimeSearchResult(id: 17617, title: "葬送的芙莉莲", typeDescription: "TV动画", imageURL: nil, episodeCount: 28),
                AnimeSearchResult(id: 18886, title: "葬送的芙莉莲 第二季", typeDescription: "TV动画", imageURL: nil, episodeCount: 10),
            ],
            episodesByAnimeID: [
                17617: [
                    AnimeEpisode(id: 176170001, number: 1, title: "第1话 冒险结束"),
                    AnimeEpisode(id: 176170002, number: 2, title: "第2话 不见得一定是靠魔法"),
                ],
                18886: [
                    AnimeEpisode(id: 188860029, number: 29, title: "第29话 那我们走吧"),
                    AnimeEpisode(id: 188860030, number: 30, title: "第30话 南方勇者"),
                    AnimeEpisode(id: 1888600, number: nil, title: "C1 Opening"),
                ],
            ],
            commentsByEpisodeID: [
                188860030: [DanmakuComment(time: 1.0, text: "season2-ep2", presentation: .scroll, color: .white)],
            ]
        )

        let store = DanmakuFeatureStore(client: client)
        store.prepareSearch(query: "葬送的芙莉莲", inferredSeasonNumber: 2, inferredEpisodeNumber: 2)

        let episode = try await store.searchAndAutoloadDanmaku()

        XCTAssertEqual(store.selectedAnimeID, 18886)
        XCTAssertEqual(store.selectedEpisodeID, 188860030)
        XCTAssertEqual(episode?.id, 188860030)
        store.renderer.sync(playbackTime: 1.0, viewportSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(store.renderer.activeItems.map(\.comment.text), ["season2-ep2"])
    }

    func testSearchAndAutoloadUsesPersistedAnimeMappingBeforeSearch() async throws {
        let client = MockDandanplayClient(
            searchResults: [],
            episodesByAnimeID: [
                18886: [
                    AnimeEpisode(id: 188860029, number: 29, title: "第29话 那我们走吧"),
                    AnimeEpisode(id: 188860030, number: 30, title: "第30话 南方勇者"),
                ],
            ],
            commentsByEpisodeID: [
                188860030: [DanmakuComment(time: 1.0, text: "mapped", presentation: .scroll, color: .white)],
            ]
        )
        let mappingStore = DanmakuMatchMappingStore(
            snapshot: DanmakuMatchMappingSnapshot(
                animeMappings: [
                    "series-1#season-2": DanmakuAnimeMapping(
                        sourceSeriesID: "series-1",
                        sourceSeasonID: "season-2",
                        animeID: 18886,
                        animeTitle: "葬送的芙莉莲 第二季",
                        updatedAt: Date(timeIntervalSince1970: 1)
                    ),
                ]
            )
        )
        let store = DanmakuFeatureStore(client: client, mappingStore: mappingStore)
        store.prepareSearch(
            query: "葬送的芙莉莲",
            inferredSeasonNumber: 2,
            inferredEpisodeNumber: 2,
            remoteSeriesID: "series-1",
            remoteSeasonID: "season-2",
            remoteEpisodeID: "episode-2"
        )

        let episode = try await store.searchAndAutoloadDanmaku()

        let searchCallCount = await client.searchCallCount()

        XCTAssertEqual(episode?.id, 188860030)
        XCTAssertEqual(store.selectedAnimeID, 18886)
        XCTAssertEqual(searchCallCount, 0)
    }

    func testRenderConfigurationPersistsAcrossStoreInstances() async throws {
        let suiteName = "DanmakuFeatureStoreTests.renderConfiguration"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let initialStore = DanmakuFeatureStore(
            client: MockDandanplayClient(),
            userDefaults: defaults
        )
        initialStore.renderConfiguration = DanmakuRenderConfiguration(
            fontStyle: .systemSerif,
            fontSize: 31,
            displayArea: .half,
            opacity: 0.42
        )

        let reloadedStore = DanmakuFeatureStore(
            client: MockDandanplayClient(),
            userDefaults: defaults
        )

        XCTAssertEqual(
            reloadedStore.renderConfiguration,
            DanmakuRenderConfiguration(
                fontStyle: .systemSerif,
                fontSize: 31,
                displayArea: .half,
                opacity: 0.42
            )
        )
        XCTAssertEqual(
            reloadedStore.renderer.configuration,
            reloadedStore.renderConfiguration
        )

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRenderConfigurationDecodesLegacyPayloadWithDefaultOpacity()
        throws
    {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "fontStyle": DanmakuFontStyle.systemSans.rawValue,
                "fontSize": 26,
                "displayArea": DanmakuDisplayArea.full.rawValue,
            ]
        )

        let configuration = try JSONDecoder().decode(
            DanmakuRenderConfiguration.self,
            from: data
        )

        XCTAssertEqual(configuration.fontStyle, .systemSans)
        XCTAssertEqual(configuration.fontSize, 26)
        XCTAssertEqual(configuration.displayArea, .full)
        XCTAssertEqual(configuration.opacity, 0.66, accuracy: 0.0001)
    }

    func testSearchAndAutoloadPredictsEpisodeFromExistingMapping() async throws {
        let client = MockDandanplayClient(
            searchResults: [],
            episodesByAnimeID: [
                18886: [
                    AnimeEpisode(id: 188860029, number: 29, title: "第29话 那我们走吧"),
                    AnimeEpisode(id: 188860030, number: 30, title: "第30话 南方勇者"),
                    AnimeEpisode(id: 188860031, number: 31, title: "第31话 帝都归来"),
                    AnimeEpisode(id: 1888600, number: nil, title: "C1 Opening"),
                ],
            ],
            commentsByEpisodeID: [
                188860031: [DanmakuComment(time: 1.0, text: "predicted", presentation: .scroll, color: .white)],
            ]
        )
        let mappingStore = DanmakuMatchMappingStore(
            snapshot: DanmakuMatchMappingSnapshot(
                animeMappings: [
                    "series-1#season-2": DanmakuAnimeMapping(
                        sourceSeriesID: "series-1",
                        sourceSeasonID: "season-2",
                        animeID: 18886,
                        animeTitle: "葬送的芙莉莲 第二季",
                        updatedAt: Date(timeIntervalSince1970: 1)
                    ),
                ],
                episodeMappings: [
                    "episode-2": DanmakuEpisodeMapping(
                        sourceEpisodeID: "episode-2",
                        sourceSeriesID: "series-1",
                        sourceSeasonID: "season-2",
                        sourceEpisodeNumber: 2,
                        animeID: 18886,
                        animeTitle: "葬送的芙莉莲 第二季",
                        animeEpisodeID: 188860030,
                        animeEpisodeNumber: 30,
                        animeEpisodeTitle: "第30话 南方勇者",
                        updatedAt: Date(timeIntervalSince1970: 2)
                    ),
                ]
            )
        )
        let store = DanmakuFeatureStore(client: client, mappingStore: mappingStore)
        store.prepareSearch(
            query: "葬送的芙莉莲",
            inferredSeasonNumber: 2,
            inferredEpisodeNumber: 3,
            remoteSeriesID: "series-1",
            remoteSeasonID: "season-2",
            remoteEpisodeID: "episode-3"
        )

        let episode = try await store.searchAndAutoloadDanmaku()

        XCTAssertEqual(episode?.id, 188860031)
        XCTAssertEqual(store.selectedEpisodeID, 188860031)
        store.renderer.sync(playbackTime: 1.0, viewportSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(store.renderer.activeItems.map(\.comment.text), ["predicted"])
    }

    func testSearchAndAutoloadPersistsRemoteMappingsAfterSuccessfulMatch() async throws {
        let client = MockDandanplayClient(
            searchResults: [
                AnimeSearchResult(id: 100, title: "Frieren", typeDescription: "TV", imageURL: nil, episodeCount: 28),
            ],
            episodesByAnimeID: [
                100: [
                    AnimeEpisode(id: 1, number: 1, title: "旅立ち"),
                    AnimeEpisode(id: 2, number: 2, title: "魔法使い"),
                ],
            ],
            commentsByEpisodeID: [
                2: [DanmakuComment(time: 1.0, text: "picked", presentation: .scroll, color: .white)],
            ]
        )
        let mappingStore = DanmakuMatchMappingStore(snapshot: DanmakuMatchMappingSnapshot())
        let store = DanmakuFeatureStore(client: client, mappingStore: mappingStore)
        store.prepareSearch(
            query: "Frieren",
            inferredSeasonNumber: 1,
            inferredEpisodeNumber: 2,
            remoteSeriesID: "series-1",
            remoteSeasonID: "season-1",
            remoteEpisodeID: "episode-2"
        )

        _ = try await store.searchAndAutoloadDanmaku()
        let snapshot = await mappingStore.snapshotForTesting()

        XCTAssertEqual(snapshot.animeMappings["series-1#season-1"]?.animeID, 100)
        XCTAssertEqual(snapshot.episodeMappings["episode-2"]?.animeEpisodeID, 2)
        XCTAssertEqual(snapshot.episodeMappings["episode-2"]?.sourceEpisodeNumber, 2)
    }

    func testSearchAndAutoloadCanSkipPersistingRemoteMappings() async throws {
        let client = MockDandanplayClient(
            searchResults: [
                AnimeSearchResult(
                    id: 100,
                    title: "Frieren",
                    typeDescription: "TV",
                    imageURL: nil,
                    episodeCount: 28
                ),
            ],
            episodesByAnimeID: [
                100: [
                    AnimeEpisode(id: 1, number: 1, title: "旅立ち"),
                    AnimeEpisode(id: 2, number: 2, title: "魔法使い"),
                ],
            ],
            commentsByEpisodeID: [
                2: [
                    DanmakuComment(
                        time: 1.0,
                        text: "picked",
                        presentation: .scroll,
                        color: .white
                    )
                ],
            ]
        )
        let mappingStore = DanmakuMatchMappingStore(
            snapshot: DanmakuMatchMappingSnapshot()
        )
        let store = DanmakuFeatureStore(
            client: client,
            mappingStore: mappingStore
        )
        store.prepareSearch(
            query: "Frieren",
            inferredSeasonNumber: 1,
            inferredEpisodeNumber: 2,
            remoteSeriesID: "series-1",
            remoteSeasonID: "season-1",
            remoteEpisodeID: "episode-2"
        )

        let episode = try await store.searchAndAutoloadDanmaku(
            persistRemoteMapping: false
        )
        let snapshot = await mappingStore.snapshotForTesting()

        XCTAssertEqual(episode?.id, 2)
        XCTAssertTrue(snapshot.animeMappings.isEmpty)
        XCTAssertTrue(snapshot.episodeMappings.isEmpty)
    }

    func testOfflineCachePayloadRoundTripsThroughJSON() throws {
        let payload = DanmakuOfflineCachePayload(
            anime: AnimeSearchResult(
                id: 100,
                title: "Frieren",
                typeDescription: "TV",
                imageURL: nil,
                episodeCount: 28
            ),
            episode: AnimeEpisode(id: 2, number: 2, title: "魔法使い"),
            comments: [
                DanmakuComment(
                    time: 1.0,
                    text: "cached",
                    presentation: .scroll,
                    color: .white
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            DanmakuOfflineCachePayload.self,
            from: JSONEncoder().encode(payload)
        )

        XCTAssertEqual(decoded.anime.id, payload.anime.id)
        XCTAssertEqual(decoded.episode.id, payload.episode.id)
        XCTAssertEqual(decoded.comments.map(\.text), ["cached"])
    }

    func testLoadOfflineCacheRestoresSelectionAndRenderer() {
        let store = DanmakuFeatureStore(client: MockDandanplayClient())
        let payload = DanmakuOfflineCachePayload(
            anime: AnimeSearchResult(
                id: 100,
                title: "Frieren",
                typeDescription: "TV",
                imageURL: nil,
                episodeCount: 28
            ),
            episode: AnimeEpisode(id: 2, number: 2, title: "魔法使い"),
            comments: [
                DanmakuComment(
                    time: 1.0,
                    text: "cached",
                    presentation: .scroll,
                    color: .white
                )
            ]
        )

        store.loadOfflineCache(payload, fallbackQuery: "葬送的芙莉莲")

        XCTAssertEqual(store.searchQuery, "葬送的芙莉莲")
        XCTAssertEqual(store.selectedAnimeID, 100)
        XCTAssertEqual(store.selectedEpisodeID, 2)
        store.renderer.sync(
            playbackTime: 1.0,
            viewportSize: CGSize(width: 1280, height: 720)
        )
        XCTAssertEqual(store.renderer.activeItems.map(\.comment.text), ["cached"])
    }

    func testPersistCurrentRemoteMappingPersistsOfflineCachedSelection()
        async
    {
        let mappingStore = DanmakuMatchMappingStore(
            snapshot: DanmakuMatchMappingSnapshot()
        )
        let store = DanmakuFeatureStore(
            client: MockDandanplayClient(),
            mappingStore: mappingStore
        )
        store.prepareSearch(
            query: "Frieren",
            inferredSeasonNumber: 1,
            inferredEpisodeNumber: 2,
            remoteSeriesID: "series-1",
            remoteSeasonID: "season-1",
            remoteEpisodeID: "episode-2"
        )
        store.loadOfflineCache(
            DanmakuOfflineCachePayload(
                anime: AnimeSearchResult(
                    id: 100,
                    title: "Frieren",
                    typeDescription: "TV",
                    imageURL: nil,
                    episodeCount: 28
                ),
                episode: AnimeEpisode(id: 2, number: 2, title: "魔法使い"),
                comments: []
            )
        )

        await store.persistCurrentRemoteMappingIfNeeded()
        let snapshot = await mappingStore.snapshotForTesting()

        XCTAssertEqual(snapshot.animeMappings["series-1#season-1"]?.animeID, 100)
        XCTAssertEqual(snapshot.episodeMappings["episode-2"]?.animeEpisodeID, 2)
        XCTAssertEqual(
            snapshot.episodeMappings["episode-2"]?.sourceEpisodeNumber,
            2
        )
    }
}
