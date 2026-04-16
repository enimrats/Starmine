import XCTest
@testable import StarmineCore

actor MockJellyfinClient: JellyfinClientProtocol {
    let snapshotValue: JellyfinStoreSnapshot
    let librariesByAccountID: [UUID: [JellyfinLibrary]]
    let itemsByLibraryID: [String: [JellyfinMediaItem]]
    let seasonsBySeriesID: [String: [JellyfinSeason]]
    let episodesBySeasonID: [String: [JellyfinEpisode]]
    let adjacentEpisodesByEpisodeID: [String: [JellyfinEpisode]]
    let resumeItemsByAccountID: [UUID: [JellyfinHomeItem]]
    let recentItemsByAccountID: [UUID: [JellyfinHomeItem]]
    let nextUpByAccountID: [UUID: [JellyfinHomeItem]]
    let recommendedItemsByAccountID: [UUID: [JellyfinHomeItem]]
    let playbackSessionsByItemID: [String: JellyfinPlaybackSession]
    var lastRememberedLibraryID: String?
    private(set) var startedPlaybackCount = 0
    private(set) var progressPlaybackCount = 0
    private(set) var stoppedPlaybackCount = 0
    private(set) var markedPlayedItemIDs: [String] = []
    private(set) var markedUnplayedItemIDs: [String] = []

    init(
        snapshotValue: JellyfinStoreSnapshot = .init(accounts: [], activeAccountID: nil),
        librariesByAccountID: [UUID: [JellyfinLibrary]] = [:],
        itemsByLibraryID: [String: [JellyfinMediaItem]] = [:],
        seasonsBySeriesID: [String: [JellyfinSeason]] = [:],
        episodesBySeasonID: [String: [JellyfinEpisode]] = [:],
        adjacentEpisodesByEpisodeID: [String: [JellyfinEpisode]] = [:],
        resumeItemsByAccountID: [UUID: [JellyfinHomeItem]] = [:],
        recentItemsByAccountID: [UUID: [JellyfinHomeItem]] = [:],
        nextUpByAccountID: [UUID: [JellyfinHomeItem]] = [:],
        recommendedItemsByAccountID: [UUID: [JellyfinHomeItem]] = [:],
        playbackSessionsByItemID: [String: JellyfinPlaybackSession] = [:]
    ) {
        self.snapshotValue = snapshotValue
        self.librariesByAccountID = librariesByAccountID
        self.itemsByLibraryID = itemsByLibraryID
        self.seasonsBySeriesID = seasonsBySeriesID
        self.episodesBySeasonID = episodesBySeasonID
        self.adjacentEpisodesByEpisodeID = adjacentEpisodesByEpisodeID
        self.resumeItemsByAccountID = resumeItemsByAccountID
        self.recentItemsByAccountID = recentItemsByAccountID
        self.nextUpByAccountID = nextUpByAccountID
        self.recommendedItemsByAccountID = recommendedItemsByAccountID
        self.playbackSessionsByItemID = playbackSessionsByItemID
    }

    func snapshot() async -> JellyfinStoreSnapshot {
        snapshotValue
    }

    func connect(serverURL: String, username: String, password: String, routeName: String?) async throws -> JellyfinStoreSnapshot {
        snapshotValue
    }

    func setActiveAccount(_ accountID: UUID) async throws -> JellyfinStoreSnapshot {
        snapshotValue
    }

    func removeAccount(_ accountID: UUID) async throws -> JellyfinStoreSnapshot {
        snapshotValue
    }

    func addRoute(accountID: UUID, serverURL: String, routeName: String?) async throws -> JellyfinStoreSnapshot {
        snapshotValue
    }

    func switchRoute(accountID: UUID, routeID: UUID) async throws -> JellyfinStoreSnapshot {
        snapshotValue
    }

    func rememberSelectedLibrary(accountID: UUID, libraryID: String?) async -> JellyfinStoreSnapshot {
        lastRememberedLibraryID = libraryID
        return snapshotValue
    }

    func loadLibraries(accountID: UUID) async throws -> [JellyfinLibrary] {
        librariesByAccountID[accountID] ?? []
    }

    func loadLibraryItems(accountID: UUID, libraryID: String) async throws -> [JellyfinMediaItem] {
        itemsByLibraryID[libraryID] ?? []
    }

    func loadSeasons(accountID: UUID, seriesID: String) async throws -> [JellyfinSeason] {
        seasonsBySeriesID[seriesID] ?? []
    }

    func loadEpisodes(accountID: UUID, seriesID: String, seasonID: String) async throws -> [JellyfinEpisode] {
        episodesBySeasonID[seasonID] ?? []
    }

    func loadAdjacentEpisodes(accountID: UUID, episodeID: String) async throws -> [JellyfinEpisode] {
        adjacentEpisodesByEpisodeID[episodeID] ?? []
    }

    func loadResumeItems(accountID: UUID, limit: Int) async throws -> [JellyfinHomeItem] {
        Array((resumeItemsByAccountID[accountID] ?? []).prefix(limit))
    }

    func loadRecentItems(accountID: UUID, limit: Int) async throws -> [JellyfinHomeItem] {
        Array((recentItemsByAccountID[accountID] ?? []).prefix(limit))
    }

    func loadNextUp(accountID: UUID, limit: Int) async throws -> [JellyfinHomeItem] {
        Array((nextUpByAccountID[accountID] ?? []).prefix(limit))
    }

    func loadRecommendedItems(accountID: UUID, limit: Int) async throws -> [JellyfinHomeItem] {
        Array((recommendedItemsByAccountID[accountID] ?? []).prefix(limit))
    }

    func createPlaybackSession(accountID: UUID, itemID: String, mediaSourceID: String?) async throws -> JellyfinPlaybackSession {
        playbackSessionsByItemID[itemID] ?? JellyfinPlaybackSession(
            itemID: itemID,
            mediaSourceID: mediaSourceID,
            playSessionID: nil,
            streamURL: URL(string: "http://example.com/\(itemID).mp4")!,
            mediaSources: []
        )
    }

    func reportPlaybackStarted(accountID: UUID, session: JellyfinPlaybackSession, positionSeconds: Double, isPaused: Bool) async throws {
        startedPlaybackCount += 1
    }

    func reportPlaybackProgress(accountID: UUID, session: JellyfinPlaybackSession, positionSeconds: Double, isPaused: Bool) async throws {
        progressPlaybackCount += 1
    }

    func reportPlaybackStopped(accountID: UUID, session: JellyfinPlaybackSession, positionSeconds: Double, isPaused: Bool, finished: Bool) async throws {
        stoppedPlaybackCount += 1
    }

    func markPlayed(accountID: UUID, itemID: String) async throws {
        markedPlayedItemIDs.append(itemID)
    }

    func markUnplayed(accountID: UUID, itemID: String) async throws {
        markedUnplayedItemIDs.append(itemID)
    }

    func rememberedLibraryID() async -> String? {
        lastRememberedLibraryID
    }

    func playbackReportCounts() async -> (Int, Int, Int) {
        (startedPlaybackCount, progressPlaybackCount, stoppedPlaybackCount)
    }

    func playedMutationCalls() async -> ([String], [String]) {
        (markedPlayedItemIDs, markedUnplayedItemIDs)
    }
}

@MainActor
final class JellyfinStoreTests: XCTestCase {
    func testRestoreStateRefreshesRememberedLibrary() async throws {
        let accountID = UUID()
        let account = JellyfinAccountProfile(
            id: accountID,
            serverID: "server",
            serverName: "Jellyfin",
            username: "alice",
            userID: "user",
            accessToken: "token",
            routes: [JellyfinRoute(name: "default", url: "http://example.com")],
            lastSelectedLibraryID: "tv"
        )
        let client = MockJellyfinClient(
            snapshotValue: JellyfinStoreSnapshot(accounts: [account], activeAccountID: accountID),
            librariesByAccountID: [
                accountID: [
                    JellyfinLibrary(payload: ["Id": "tv", "Name": "TV", "CollectionType": "tvshows"]),
                    JellyfinLibrary(payload: ["Id": "movie", "Name": "Movie", "CollectionType": "movies"]),
                ],
            ],
            itemsByLibraryID: [
                "tv": [JellyfinMediaItem(payload: ["Id": "series-1", "Name": "Frieren", "Type": "Series"])],
            ]
        )

        let store = JellyfinStore(client: client)
        try await store.restoreState()

        XCTAssertEqual(store.selectedAccountID, accountID)
        XCTAssertEqual(store.selectedLibraryID, "tv")
        XCTAssertEqual(store.items.map(\.id), ["series-1"])
        let rememberedLibraryID = await client.rememberedLibraryID()
        XCTAssertEqual(rememberedLibraryID, "tv")
    }

    func testSelectItemLoadsSeasonsAndDefaultEpisodesForSeries() async throws {
        let accountID = UUID()
        let season = JellyfinSeason(payload: ["Id": "season-1", "Name": "Season 1", "SeriesId": "series-1", "IndexNumber": 1])
        let episode = JellyfinEpisode(payload: ["Id": "ep-1", "Name": "Episode 1", "SeriesId": "series-1", "SeasonId": "season-1", "IndexNumber": 1])
        let client = MockJellyfinClient(
            seasonsBySeriesID: ["series-1": [season]],
            episodesBySeasonID: ["season-1": [episode]]
        )

        let store = JellyfinStore(client: client)
        store.selectedAccountID = accountID

        let item = JellyfinMediaItem(payload: ["Id": "series-1", "Name": "Frieren", "Type": "Series"])
        try await store.selectItem(item)

        XCTAssertEqual(store.selectedItemID, "series-1")
        XCTAssertEqual(store.selectedSeasonID, "season-1")
        XCTAssertEqual(store.episodes.map(\.id), ["ep-1"])
    }

    func testMakePlaybackCandidateForEpisodeResolvesNeighbors() async throws {
        let accountID = UUID()
        let previous = JellyfinEpisode(payload: ["Id": "ep-1", "Name": "Episode 1", "SeriesName": "Frieren", "SeriesId": "series-1", "SeasonId": "season-1", "IndexNumber": 1, "ParentIndexNumber": 1])
        let current = JellyfinEpisode(payload: ["Id": "ep-2", "Name": "Episode 2", "SeriesName": "Frieren", "SeriesId": "series-1", "SeasonId": "season-1", "IndexNumber": 2, "ParentIndexNumber": 1])
        let next = JellyfinEpisode(payload: ["Id": "ep-3", "Name": "Episode 3", "SeriesName": "Frieren", "SeriesId": "series-1", "SeasonId": "season-1", "IndexNumber": 3, "ParentIndexNumber": 1])
        let client = MockJellyfinClient(
            playbackSessionsByItemID: [
                "ep-2": JellyfinPlaybackSession(
                    itemID: "ep-2",
                    mediaSourceID: "source",
                    playSessionID: "session",
                    streamURL: URL(string: "http://example.com/ep-2.mp4")!,
                    mediaSources: []
                ),
            ]
        )

        let store = JellyfinStore(client: client)
        store.selectedAccountID = accountID
        store.episodes = [previous, current, next]

        let candidate = try await store.makePlaybackCandidate(for: current)

        XCTAssertEqual(candidate.title, "Frieren")
        XCTAssertEqual(candidate.episodeLabel, "S1E2 · Episode 2")
        XCTAssertEqual(candidate.danmakuQuery, "Frieren")
        XCTAssertEqual(candidate.remoteSeriesID, "series-1")
        XCTAssertEqual(candidate.remoteSeasonID, "season-1")
        XCTAssertEqual(candidate.remoteEpisodeID, "ep-2")
        XCTAssertEqual(candidate.seasonNumber, 1)
        XCTAssertEqual(candidate.seasonEpisodeCount, 3)
        XCTAssertEqual(candidate.episodeNumber, 2)
        XCTAssertEqual(store.selectedEpisodeID, "ep-2")
        XCTAssertTrue(store.canPlayPreviousEpisode)
        XCTAssertTrue(store.canPlayNextEpisode)
    }

    func testRefreshLibraryFallsBackToFirstLibraryWhenRememberedSelectionIsMissing() async throws {
        let accountID = UUID()
        let account = JellyfinAccountProfile(
            id: accountID,
            serverID: "server",
            serverName: "Jellyfin",
            username: "alice",
            userID: "user",
            accessToken: "token",
            routes: [JellyfinRoute(name: "default", url: "http://example.com")],
            lastSelectedLibraryID: "missing"
        )
        let client = MockJellyfinClient(
            snapshotValue: JellyfinStoreSnapshot(accounts: [account], activeAccountID: accountID),
            librariesByAccountID: [
                accountID: [JellyfinLibrary(payload: ["Id": "tv", "Name": "TV", "CollectionType": "tvshows"])],
            ],
            itemsByLibraryID: ["tv": []]
        )

        let store = JellyfinStore(client: client)
        store.selectedAccountID = accountID
        store.accounts = [account]

        try await store.refreshLibrary()

        XCTAssertEqual(store.selectedLibraryID, "tv")
        let rememberedLibraryID = await client.rememberedLibraryID()
        XCTAssertEqual(rememberedLibraryID, "tv")
    }

    func testRemoveAccountRefreshesReplacementActiveAccount() async throws {
        let removedAccountID = UUID()
        let remainingAccountID = UUID()
        let removedAccount = JellyfinAccountProfile(
            id: removedAccountID,
            serverID: "server-1",
            serverName: "Jellyfin A",
            username: "alice",
            userID: "user-1",
            accessToken: "token-1",
            routes: [JellyfinRoute(name: "default", url: "http://example.com")]
        )
        let remainingAccount = JellyfinAccountProfile(
            id: remainingAccountID,
            serverID: "server-2",
            serverName: "Jellyfin B",
            username: "bob",
            userID: "user-2",
            accessToken: "token-2",
            routes: [JellyfinRoute(name: "default", url: "http://example.org")]
        )
        let client = MockJellyfinClient(
            snapshotValue: JellyfinStoreSnapshot(
                accounts: [remainingAccount],
                activeAccountID: remainingAccountID
            ),
            librariesByAccountID: [
                remainingAccountID: [
                    JellyfinLibrary(
                        payload: [
                            "Id": "movies",
                            "Name": "Movies",
                            "CollectionType": "movies",
                        ]
                    )
                ]
            ],
            itemsByLibraryID: [
                "movies": [
                    JellyfinMediaItem(
                        payload: [
                            "Id": "movie-1",
                            "Name": "Paprika",
                            "Type": "Movie",
                        ]
                    )
                ]
            ]
        )

        let store = JellyfinStore(client: client)
        store.accounts = [removedAccount, remainingAccount]
        store.selectedAccountID = removedAccountID
        store.selectedLibraryID = "old-library"
        store.items = [
            JellyfinMediaItem(
                payload: [
                    "Id": "old-item",
                    "Name": "Old Item",
                    "Type": "Movie",
                ]
            )
        ]

        try await store.removeAccount(removedAccountID)

        XCTAssertEqual(store.selectedAccountID, remainingAccountID)
        XCTAssertEqual(store.selectedLibraryID, "movies")
        XCTAssertEqual(store.items.map(\.id), ["movie-1"])
    }

    func testRefreshHomeLoadsShelvesForActiveAccount() async throws {
        let accountID = UUID()
        let account = JellyfinAccountProfile(
            id: accountID,
            serverID: "server",
            serverName: "Jellyfin",
            username: "alice",
            userID: "user",
            accessToken: "token",
            routes: [JellyfinRoute(name: "default", url: "http://example.com")]
        )
        let client = MockJellyfinClient(
            snapshotValue: JellyfinStoreSnapshot(
                accounts: [account],
                activeAccountID: accountID
            ),
            resumeItemsByAccountID: [
                accountID: [
                    JellyfinHomeItem(
                        payload: [
                            "Id": "resume-1",
                            "Name": "Episode 1",
                            "Type": "Episode",
                            "SeriesName": "Frieren",
                            "SeriesId": "series-1",
                            "SeasonId": "season-1",
                            "IndexNumber": 1,
                            "ParentIndexNumber": 1,
                        ]
                    )
                ]
            ],
            recentItemsByAccountID: [
                accountID: [
                    JellyfinHomeItem(
                        payload: [
                            "Id": "recent-1",
                            "Name": "Movie",
                            "Type": "Movie",
                        ]
                    )
                ]
            ],
            nextUpByAccountID: [
                accountID: [
                    JellyfinHomeItem(
                        payload: [
                            "Id": "next-1",
                            "Name": "Episode 2",
                            "Type": "Episode",
                            "SeriesName": "Frieren",
                            "SeriesId": "series-1",
                            "SeasonId": "season-1",
                            "IndexNumber": 2,
                            "ParentIndexNumber": 1,
                        ]
                    )
                ]
            ],
            recommendedItemsByAccountID: [
                accountID: [
                    JellyfinHomeItem(
                        payload: [
                            "Id": "rec-1",
                            "Name": "Sousou no Frieren",
                            "Type": "Series",
                        ]
                    )
                ]
            ]
        )

        let store = JellyfinStore(client: client)
        store.accounts = [account]
        store.selectedAccountID = accountID

        try await store.refreshHome()

        XCTAssertEqual(store.resumeItems.map(\.id), ["resume-1"])
        XCTAssertEqual(store.recentItems.map(\.id), ["recent-1"])
        XCTAssertEqual(store.nextUpItems.map(\.id), ["next-1"])
        XCTAssertEqual(store.recommendedItems.map(\.id), ["rec-1"])
    }

    func testPlaybackTrackingUpdatesResumeItemsAndReportsLifecycle() async throws {
        let accountID = UUID()
        let account = JellyfinAccountProfile(
            id: accountID,
            serverID: "server",
            serverName: "Jellyfin",
            username: "alice",
            userID: "user",
            accessToken: "token",
            routes: [JellyfinRoute(name: "default", url: "http://example.com")]
        )
        let session = JellyfinPlaybackSession(
            itemID: "movie-1",
            mediaSourceID: "source-1",
            playSessionID: "play-1",
            streamURL: URL(string: "http://example.com/movie-1.mp4")!,
            mediaSources: []
        )
        let client = MockJellyfinClient(
            snapshotValue: JellyfinStoreSnapshot(
                accounts: [account],
                activeAccountID: accountID
            ),
            recentItemsByAccountID: [
                accountID: [
                    JellyfinHomeItem(
                        payload: [
                            "Id": "movie-1",
                            "Name": "Movie",
                            "Type": "Movie",
                            "RunTimeTicks": 7_200_000_000 as Double,
                        ]
                    )
                ]
            ],
            playbackSessionsByItemID: [
                "movie-1": session
            ]
        )

        let store = JellyfinStore(client: client)
        store.accounts = [account]
        store.selectedAccountID = accountID
        store.recentItems = [
            JellyfinHomeItem(
                payload: [
                    "Id": "movie-1",
                    "Name": "Movie",
                    "Type": "Movie",
                    "RunTimeTicks": 7_200_000_000 as Double,
                ]
            )
        ]

        let candidate = JellyfinPlaybackCandidate(
            session: session,
            itemKind: .movie,
            title: "Movie",
            episodeLabel: "",
            collectionTitle: nil,
            danmakuQuery: "Movie",
            remoteSeriesID: nil,
            remoteSeasonID: nil,
            remoteEpisodeID: nil,
            seasonNumber: nil,
            seasonEpisodeCount: nil,
            episodeNumber: nil,
            resumePosition: nil
        )

        await store.beginPlaybackTracking(candidate: candidate, initialPosition: 12, isPaused: false)
        await store.reportActivePlaybackProgress(
            positionSeconds: 42,
            durationSeconds: 720,
            isPaused: false,
            force: true
        )
        XCTAssertEqual(store.resumeItems.first?.id, "movie-1")
        XCTAssertEqual(
            store.resumeItems.first?.resumePositionSeconds ?? -1,
            42,
            accuracy: 0.1
        )

        await store.finishPlaybackTracking(
            positionSeconds: 128,
            durationSeconds: 720,
            isPaused: true,
            finished: false
        )

        let counts = await client.playbackReportCounts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 1)
    }

    func testFocusLibraryContextForEpisodeSelectsSeriesSeasonAndEpisode() async throws {
        let accountID = UUID()
        let account = JellyfinAccountProfile(
            id: accountID,
            serverID: "server",
            serverName: "Jellyfin",
            username: "alice",
            userID: "user",
            accessToken: "token",
            routes: [JellyfinRoute(name: "default", url: "http://example.com")]
        )
        let season1 = JellyfinSeason(
            payload: [
                "Id": "season-1",
                "Name": "Season 1",
                "SeriesId": "series-1",
                "IndexNumber": 1,
            ]
        )
        let season2 = JellyfinSeason(
            payload: [
                "Id": "season-2",
                "Name": "Season 2",
                "SeriesId": "series-1",
                "IndexNumber": 2,
            ]
        )
        let episode = JellyfinEpisode(
            payload: [
                "Id": "ep-3",
                "Name": "Episode 3",
                "SeriesName": "Frieren",
                "SeriesId": "series-1",
                "SeasonId": "season-2",
                "IndexNumber": 3,
                "ParentIndexNumber": 2,
            ]
        )

        let client = MockJellyfinClient(
            snapshotValue: JellyfinStoreSnapshot(
                accounts: [account],
                activeAccountID: accountID
            ),
            seasonsBySeriesID: [
                "series-1": [season1, season2]
            ],
            episodesBySeasonID: [
                "season-1": [],
                "season-2": [episode]
            ]
        )

        let store = JellyfinStore(client: client)
        store.accounts = [account]
        store.selectedAccountID = accountID

        try await store.focusLibraryContext(
            for: JellyfinHomeItem(
                payload: [
                    "Id": "ep-3",
                    "Name": "Episode 3",
                    "Type": "Episode",
                    "SeriesName": "Frieren",
                    "SeriesId": "series-1",
                    "SeasonId": "season-2",
                    "IndexNumber": 3,
                    "ParentIndexNumber": 2,
                ]
            )
        )

        XCTAssertEqual(store.selectedItemID, "series-1")
        XCTAssertEqual(store.selectedSeasonID, "season-2")
        XCTAssertEqual(store.selectedEpisodeID, "ep-3")
        XCTAssertEqual(store.episodes.map(\.id), ["ep-3"])
    }

    func testFocusLibraryContextFallsBackToSeasonNumberWhenSeasonIDMissing() async throws {
        let accountID = UUID()
        let account = JellyfinAccountProfile(
            id: accountID,
            serverID: "server",
            serverName: "Jellyfin",
            username: "alice",
            userID: "user",
            accessToken: "token",
            routes: [JellyfinRoute(name: "default", url: "http://example.com")]
        )
        let season1 = JellyfinSeason(
            payload: [
                "Id": "season-1",
                "Name": "Season 1",
                "SeriesId": "series-1",
                "IndexNumber": 1,
            ]
        )
        let season2 = JellyfinSeason(
            payload: [
                "Id": "season-2",
                "Name": "Season 2",
                "SeriesId": "series-1",
                "IndexNumber": 2,
            ]
        )
        let episode = JellyfinEpisode(
            payload: [
                "Id": "ep-3",
                "Name": "Episode 3",
                "SeriesName": "Frieren",
                "SeriesId": "series-1",
                "SeasonId": "season-2",
                "IndexNumber": 3,
                "ParentIndexNumber": 2,
            ]
        )

        let client = MockJellyfinClient(
            snapshotValue: JellyfinStoreSnapshot(
                accounts: [account],
                activeAccountID: accountID
            ),
            seasonsBySeriesID: [
                "series-1": [season1, season2]
            ],
            episodesBySeasonID: [
                "season-1": [],
                "season-2": [episode]
            ]
        )

        let store = JellyfinStore(client: client)
        store.accounts = [account]
        store.selectedAccountID = accountID

        try await store.focusLibraryContext(
            for: JellyfinHomeItem(
                payload: [
                    "Id": "ep-3",
                    "Name": "Episode 3",
                    "Type": "Episode",
                    "SeriesName": "Frieren",
                    "SeriesId": "series-1",
                    "IndexNumber": 3,
                    "ParentIndexNumber": 2,
                ]
            )
        )

        XCTAssertEqual(store.selectedItemID, "series-1")
        XCTAssertEqual(store.selectedSeasonID, "season-2")
        XCTAssertEqual(store.selectedEpisodeID, "ep-3")
        XCTAssertEqual(store.episodes.map(\.id), ["ep-3"])
    }

    func testSetPlayedStateUpdatesLocalCollectionsAndCallsAPI() async throws {
        let accountID = UUID()
        let account = JellyfinAccountProfile(
            id: accountID,
            serverID: "server",
            serverName: "Jellyfin",
            username: "alice",
            userID: "user",
            accessToken: "token",
            routes: [JellyfinRoute(name: "default", url: "http://example.com")]
        )

        let client = MockJellyfinClient(
            snapshotValue: JellyfinStoreSnapshot(
                accounts: [account],
                activeAccountID: accountID
            ),
            recentItemsByAccountID: [
                accountID: [
                    JellyfinHomeItem(
                        payload: [
                            "Id": "movie-1",
                            "Name": "Movie",
                            "Type": "Movie",
                            "UserData": [
                                "Played": true,
                                "PlaybackPositionTicks": 0 as Double,
                            ],
                        ]
                    )
                ]
            ]
        )

        let movie = JellyfinMediaItem(
            payload: [
                "Id": "movie-1",
                "Name": "Movie",
                "Type": "Movie",
                "UserData": [
                    "Played": false,
                    "PlaybackPositionTicks": 120_000_000 as Double,
                ],
            ]
        )

        let store = JellyfinStore(client: client)
        store.accounts = [account]
        store.selectedAccountID = accountID
        store.items = [movie]
        store.resumeItems = [JellyfinHomeItem(mediaItem: movie)]
        store.recentItems = [JellyfinHomeItem(mediaItem: movie)]

        try await store.setPlayedState(itemID: "movie-1", played: true)

        XCTAssertTrue(store.items.first?.isPlayed == true)
        XCTAssertTrue(store.resumeItems.isEmpty)
        XCTAssertTrue(store.recentItems.first?.isPlayed == true)
        let calls = await client.playedMutationCalls()
        XCTAssertEqual(calls.0, ["movie-1"])
        XCTAssertEqual(calls.1, [])
    }
}
