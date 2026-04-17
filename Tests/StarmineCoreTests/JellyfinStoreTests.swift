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
    let userDataByItemID: [String: JellyfinUserData]
    let playbackSessionsByItemID: [String: JellyfinPlaybackSession]
    let createPlaybackSessionHandler:
        (@Sendable (UUID, String, String?) async throws -> JellyfinPlaybackSession)?
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
        userDataByItemID: [String: JellyfinUserData] = [:],
        playbackSessionsByItemID: [String: JellyfinPlaybackSession] = [:],
        createPlaybackSessionHandler: (
            @Sendable (UUID, String, String?) async throws
                -> JellyfinPlaybackSession
        )? = nil
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
        self.userDataByItemID = userDataByItemID
        self.playbackSessionsByItemID = playbackSessionsByItemID
        self.createPlaybackSessionHandler = createPlaybackSessionHandler
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

    func loadUserData(accountID: UUID, itemID: String) async throws -> JellyfinUserData {
        userDataByItemID[itemID] ?? JellyfinUserData()
    }

    func createPlaybackSession(accountID: UUID, itemID: String, mediaSourceID: String?) async throws -> JellyfinPlaybackSession {
        if let createPlaybackSessionHandler {
            return try await createPlaybackSessionHandler(
                accountID,
                itemID,
                mediaSourceID
            )
        }
        return playbackSessionsByItemID[itemID] ?? JellyfinPlaybackSession(
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

actor PlaybackSessionGate {
    private var hasStarted = false
    private var hasResumed = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func markStarted() {
        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitForStart() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitUntilResumed() async {
        guard !hasResumed else { return }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func resume() {
        hasResumed = true
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

@MainActor
final class JellyfinStoreTests: XCTestCase {
    private func makeStore(
        client: any JellyfinClientProtocol,
        offlineRootURL: URL? = nil,
        danmakuPrefetchStore: DanmakuFeatureStore? = nil
    ) -> JellyfinStore {
        let suiteName = "JellyfinStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let resolvedOfflineRootURL = offlineRootURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        return JellyfinStore(
            client: client,
            defaults: defaults,
            fileManager: .default,
            offlineRootURL: resolvedOfflineRootURL,
            danmakuPrefetchStore: danmakuPrefetchStore
        )
    }

    private func writeOfflineManifest(
        entries: [JellyfinOfflineEntry],
        offlineRootURL: URL
    ) throws {
        for entry in entries {
            let videoURL = offlineRootURL.appendingPathComponent(
                entry.videoRelativePath
            )
            try FileManager.default.createDirectory(
                at: videoURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0x00]).write(to: videoURL)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(entries).write(
            to: offlineRootURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

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

        let store = makeStore(client: client)
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

        let store = makeStore(client: client)
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

        let store = makeStore(client: client)
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

        let store = makeStore(client: client)
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

        let store = makeStore(client: client)
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

        let store = makeStore(client: client)
        store.accounts = [account]
        store.selectedAccountID = accountID
        store.homeAccountID = accountID

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

        let store = makeStore(client: client)
        store.accounts = [account]
        store.selectedAccountID = accountID
        store.homeAccountID = accountID
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
            accountID: accountID,
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

        let store = makeStore(client: client)
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

        let store = makeStore(client: client)
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

        let store = makeStore(client: client)
        store.accounts = [account]
        store.selectedAccountID = accountID
        store.homeAccountID = accountID
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

    func testOfflineLookupAndSeriesCountRespectRequestedAccount() throws {
        let activeAccountID = UUID()
        let otherAccountID = UUID()
        let activeAccount = JellyfinAccountProfile(
            id: activeAccountID,
            serverID: "server-a",
            serverName: "Jellyfin A",
            username: "alice",
            userID: "user-a",
            accessToken: "token-a",
            routes: [JellyfinRoute(name: "default", url: "http://a.example.com")]
        )
        let otherAccount = JellyfinAccountProfile(
            id: otherAccountID,
            serverID: "server-b",
            serverName: "Jellyfin B",
            username: "bob",
            userID: "user-b",
            accessToken: "token-b",
            routes: [JellyfinRoute(name: "default", url: "http://b.example.com")]
        )

        let suiteName = "JellyfinStoreTests.scope.\(UUID().uuidString)"
        let offlineRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        let movieEntryID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let episodeEntryID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let otherMovieEntry = JellyfinOfflineEntry(
            id: movieEntryID,
            serverID: otherAccount.serverID,
            userID: otherAccount.userID,
            accountDisplayTitle: otherAccount.displayTitle,
            sourceLibraryName: "Movies",
            remoteItemID: "shared-item",
            remoteItemKind: .movie,
            title: "Paprika",
            episodeLabel: "",
            collectionTitle: nil,
            overview: nil,
            seriesID: nil,
            seriesTitle: nil,
            seasonID: nil,
            seasonTitle: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            productionYear: 2006,
            communityRating: "8.10",
            runTimeTicks: 5_400_000_000,
            videoRelativePath: "Entries/\(movieEntryID.uuidString)/movie.mp4",
            posterRelativePath: nil,
            backdropRelativePath: nil,
            thumbnailRelativePath: nil,
            seasonPosterRelativePath: nil,
            subtitles: [],
            localUserData: JellyfinUserData(),
            baselineUserData: JellyfinUserData()
        )
        let otherEpisodeEntry = JellyfinOfflineEntry(
            id: episodeEntryID,
            serverID: otherAccount.serverID,
            userID: otherAccount.userID,
            accountDisplayTitle: otherAccount.displayTitle,
            sourceLibraryName: "TV",
            remoteItemID: "shared-episode",
            remoteItemKind: .episode,
            title: "Episode 1",
            episodeLabel: "S1E1 · Episode 1",
            collectionTitle: "Frieren",
            overview: nil,
            seriesID: "shared-series",
            seriesTitle: "Frieren",
            seasonID: "season-1",
            seasonTitle: "Season 1",
            seasonNumber: 1,
            episodeNumber: 1,
            productionYear: nil,
            communityRating: nil,
            runTimeTicks: 1_800_000_000,
            videoRelativePath: "Entries/\(episodeEntryID.uuidString)/episode.mp4",
            posterRelativePath: nil,
            backdropRelativePath: nil,
            thumbnailRelativePath: nil,
            seasonPosterRelativePath: nil,
            subtitles: [],
            localUserData: JellyfinUserData(),
            baselineUserData: JellyfinUserData()
        )
        try writeOfflineManifest(
            entries: [otherMovieEntry, otherEpisodeEntry],
            offlineRootURL: offlineRootURL
        )

        let store = makeStore(
            client: MockJellyfinClient(),
            offlineRootURL: offlineRootURL
        )
        store.accounts = [activeAccount, otherAccount]
        store.selectedAccountID = activeAccountID
        store.homeAccountID = activeAccountID

        XCTAssertEqual(store.offlineEntries.count, 2)
        XCTAssertNil(
            store.offlineEntry(
                forRemoteItemID: "shared-item",
                accountID: activeAccountID
            )
        )
        XCTAssertEqual(
            store.offlineEpisodeCount(
                forSeriesID: "shared-series",
                accountID: activeAccountID
            ),
            0
        )
        XCTAssertEqual(
            store.offlineEntry(
                forRemoteItemID: "shared-item",
                accountID: otherAccountID
            )?.id,
            movieEntryID
        )
        XCTAssertEqual(
            store.offlineEpisodeCount(
                forSeriesID: "shared-series",
                accountID: otherAccountID
            ),
            1
        )
    }

    func testSyncOfflineEntriesUploadsPlayedStateAndResetsConflictFields() async throws {
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
            userDataByItemID: [
                "ep-1": JellyfinUserData(
                    played: false,
                    playbackPositionTicks: 0,
                    lastPlayedDate: Date(timeIntervalSince1970: 1_000)
                )
            ]
        )

        let suiteName = "JellyfinStoreTests.offline.\(UUID().uuidString)"
        let offlineRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        let entryID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        let baseline = JellyfinUserData(
            played: false,
            playbackPositionTicks: 0,
            lastPlayedDate: Date(timeIntervalSince1970: 1_000)
        )
        let local = JellyfinUserData(
            played: true,
            playbackPositionTicks: 0,
            lastPlayedDate: Date(timeIntervalSince1970: 2_000)
        )
        let entry = JellyfinOfflineEntry(
            id: entryID,
            serverID: account.serverID,
            userID: account.userID,
            accountDisplayTitle: account.displayTitle,
            sourceLibraryName: "TV",
            remoteItemID: "ep-1",
            remoteItemKind: .episode,
            title: "Episode 1",
            episodeLabel: "S1E1 · Episode 1",
            collectionTitle: "Frieren",
            overview: nil,
            seriesID: "series-1",
            seriesTitle: "Frieren",
            seasonID: "season-1",
            seasonTitle: "Season 1",
            seasonNumber: 1,
            episodeNumber: 1,
            productionYear: nil,
            communityRating: nil,
            runTimeTicks: 1_800_000_000,
            videoRelativePath: "Entries/\(entryID.uuidString)/video.mp4",
            posterRelativePath: nil,
            backdropRelativePath: nil,
            thumbnailRelativePath: nil,
            seasonPosterRelativePath: nil,
            subtitles: [],
            localUserData: local,
            baselineUserData: baseline,
            conflictingRemoteUserData: JellyfinUserData(
                played: true,
                playbackPositionTicks: 123,
                lastPlayedDate: Date()
            ),
            syncState: .pendingUpload,
            syncErrorMessage: "stale",
            lastLocalUpdateAt: Date(timeIntervalSince1970: 2_000)
        )
        try writeOfflineManifest(
            entries: [entry],
            offlineRootURL: offlineRootURL
        )

        let store = makeStore(
            client: client,
            offlineRootURL: offlineRootURL
        )
        store.accounts = [account]
        store.selectedAccountID = accountID

        await store.syncOfflineEntriesIfPossible()

        let syncedEntry = try XCTUnwrap(store.offlineEntries.first)
        XCTAssertEqual(syncedEntry.syncState, .synced)
        XCTAssertTrue(syncedEntry.localUserData.played == true)
        XCTAssertTrue(syncedEntry.baselineUserData.played == true)
        XCTAssertNil(syncedEntry.conflictingRemoteUserData)
        XCTAssertNil(syncedEntry.syncErrorMessage)
        let calls = await client.playedMutationCalls()
        XCTAssertEqual(calls.0, ["ep-1"])
        XCTAssertEqual(calls.1, [])
    }

    func testQueueDownloadForHomeSeriesQueuesEpisodesAcrossSeasons()
        async throws
    {
        let accountID = UUID()
        let gate = PlaybackSessionGate()
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
        let episode1 = JellyfinEpisode(
            payload: [
                "Id": "ep-1",
                "Name": "Episode 1",
                "Type": "Episode",
                "SeriesId": "series-1",
                "SeriesName": "Frieren",
                "SeasonId": "season-1",
                "IndexNumber": 1,
                "ParentIndexNumber": 1,
            ]
        )
        let episode2 = JellyfinEpisode(
            payload: [
                "Id": "ep-2",
                "Name": "Episode 2",
                "Type": "Episode",
                "SeriesId": "series-1",
                "SeriesName": "Frieren",
                "SeasonId": "season-2",
                "IndexNumber": 1,
                "ParentIndexNumber": 2,
            ]
        )
        let client = MockJellyfinClient(
            seasonsBySeriesID: [
                "series-1": [season1, season2]
            ],
            episodesBySeasonID: [
                "season-1": [episode1],
                "season-2": [episode2],
            ],
            createPlaybackSessionHandler: { _, itemID, mediaSourceID in
                await gate.markStarted()
                await gate.waitUntilResumed()
                return JellyfinPlaybackSession(
                    itemID: itemID,
                    mediaSourceID: mediaSourceID,
                    playSessionID: nil,
                    streamURL: URL(fileURLWithPath: "/tmp/\(itemID).mp4"),
                    mediaSources: []
                )
            }
        )

        let store = makeStore(client: client)
        store.accounts = [account]
        store.homeAccountID = accountID

        let series = JellyfinHomeItem(
            payload: [
                "Id": "series-1",
                "Name": "Frieren",
                "Type": "Series",
            ]
        )

        try await store.queueDownload(for: series)
        await gate.waitForStart()

        XCTAssertEqual(store.offlineDownloadTasks.count, 2)
        XCTAssertEqual(
            Set(store.offlineDownloadTasks.map(\.remoteItemID)),
            Set(["ep-1", "ep-2"])
        )

        await gate.resume()
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testDeleteOfflineEntryRecomputesNavigationForActiveOfflinePlayback()
        throws
    {
        let suiteName = "JellyfinStoreTests.offline.navigation.\(UUID().uuidString)"
        let offlineRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        let entry1ID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let entry2ID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let entry3ID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        func makeEpisodeEntry(id: UUID, itemID: String, episodeNumber: Int)
            -> JellyfinOfflineEntry
        {
            JellyfinOfflineEntry(
                id: id,
                serverID: "server",
                userID: "user",
                accountDisplayTitle: "Jellyfin · alice",
                sourceLibraryName: "TV",
                remoteItemID: itemID,
                remoteItemKind: .episode,
                title: "Episode \(episodeNumber)",
                episodeLabel: "S1E\(episodeNumber) · Episode \(episodeNumber)",
                collectionTitle: "Frieren",
                overview: nil,
                seriesID: "series-1",
                seriesTitle: "Frieren",
                seasonID: "season-1",
                seasonTitle: "Season 1",
                seasonNumber: 1,
                episodeNumber: episodeNumber,
                productionYear: nil,
                communityRating: nil,
                runTimeTicks: 1_800_000_000,
                videoRelativePath: "Entries/\(id.uuidString)/ep-\(episodeNumber).mp4",
                posterRelativePath: nil,
                backdropRelativePath: nil,
                thumbnailRelativePath: nil,
                seasonPosterRelativePath: nil,
                subtitles: [],
                localUserData: JellyfinUserData(),
                baselineUserData: JellyfinUserData()
            )
        }

        let entry1 = makeEpisodeEntry(
            id: entry1ID,
            itemID: "ep-1",
            episodeNumber: 1
        )
        let entry2 = makeEpisodeEntry(
            id: entry2ID,
            itemID: "ep-2",
            episodeNumber: 2
        )
        let entry3 = makeEpisodeEntry(
            id: entry3ID,
            itemID: "ep-3",
            episodeNumber: 3
        )
        try writeOfflineManifest(
            entries: [entry1, entry2, entry3],
            offlineRootURL: offlineRootURL
        )

        let store = makeStore(
            client: MockJellyfinClient(),
            offlineRootURL: offlineRootURL
        )
        store.beginOfflinePlaybackTracking(entry: entry2)

        XCTAssertEqual(store.previousOfflineEntry?.id, entry1ID)
        XCTAssertEqual(store.nextOfflineEntry?.id, entry3ID)

        store.deleteOfflineEntry(entry1ID)
        XCTAssertNil(store.previousOfflineEntry)
        XCTAssertEqual(store.nextOfflineEntry?.id, entry3ID)

        store.deleteOfflineEntry(entry3ID)
        XCTAssertNil(store.previousOfflineEntry)
        XCTAssertNil(store.nextOfflineEntry)
    }

    func testQueueDownloadRejectsDuplicateWhileMatchingItemIsActive()
        async throws
    {
        let accountID = UUID()
        let gate = PlaybackSessionGate()
        let client = MockJellyfinClient(
            createPlaybackSessionHandler: { _, itemID, mediaSourceID in
                await gate.markStarted()
                await gate.waitUntilResumed()
                return JellyfinPlaybackSession(
                    itemID: itemID,
                    mediaSourceID: mediaSourceID,
                    playSessionID: nil,
                    streamURL: URL(fileURLWithPath: "/tmp/\(itemID).mp4"),
                    mediaSources: []
                )
            }
        )
        let store = makeStore(client: client)
        store.accounts = [
            JellyfinAccountProfile(
                id: accountID,
                serverID: "server",
                serverName: "Jellyfin",
                username: "alice",
                userID: "user",
                accessToken: "token",
                routes: [JellyfinRoute(name: "default", url: "http://example.com")]
            )
        ]
        store.selectedAccountID = accountID

        let item = JellyfinMediaItem(
            payload: ["Id": "movie-1", "Name": "Movie", "Type": "Movie"]
        )

        try await store.queueDownload(for: item)
        await gate.waitForStart()
        try await store.queueDownload(for: item)

        XCTAssertEqual(store.offlineDownloadTasks.count, 1)

        await gate.resume()
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testSetOfflinePlayedStateClearsResumePositionBeforeUnplayedSync()
        async throws
    {
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
            userDataByItemID: [
                "ep-1": JellyfinUserData(
                    played: false,
                    playbackPositionTicks: 1_200_000_000,
                    lastPlayedDate: Date(timeIntervalSince1970: 1_000)
                )
            ]
        )

        let suiteName = "JellyfinStoreTests.unplayed.\(UUID().uuidString)"
        let offlineRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        let entryID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let userData = JellyfinUserData(
            played: false,
            playbackPositionTicks: 1_200_000_000,
            lastPlayedDate: Date(timeIntervalSince1970: 1_000)
        )
        let entry = JellyfinOfflineEntry(
            id: entryID,
            serverID: account.serverID,
            userID: account.userID,
            accountDisplayTitle: account.displayTitle,
            sourceLibraryName: "TV",
            remoteItemID: "ep-1",
            remoteItemKind: .episode,
            title: "Episode 1",
            episodeLabel: "S1E1 · Episode 1",
            collectionTitle: "Frieren",
            overview: nil,
            seriesID: "series-1",
            seriesTitle: "Frieren",
            seasonID: "season-1",
            seasonTitle: "Season 1",
            seasonNumber: 1,
            episodeNumber: 1,
            productionYear: nil,
            communityRating: nil,
            runTimeTicks: 1_800_000_000,
            videoRelativePath: "Entries/\(entryID.uuidString)/video.mp4",
            posterRelativePath: nil,
            backdropRelativePath: nil,
            thumbnailRelativePath: nil,
            seasonPosterRelativePath: nil,
            subtitles: [],
            localUserData: userData,
            baselineUserData: userData,
            lastSyncAt: Date(timeIntervalSince1970: 1_000)
        )
        try writeOfflineManifest(
            entries: [entry],
            offlineRootURL: offlineRootURL
        )

        let store = makeStore(
            client: client,
            offlineRootURL: offlineRootURL
        )
        store.accounts = [account]

        store.setOfflinePlayedState(entryID: entryID, played: false)

        let updatedEntry = try XCTUnwrap(store.offlineEntries.first)
        XCTAssertEqual(updatedEntry.localUserData.playbackPositionSeconds, 0)
        XCTAssertEqual(updatedEntry.syncState, .pendingUpload)

        await store.syncOfflineEntriesIfPossible()

        let syncedEntry = try XCTUnwrap(store.offlineEntries.first)
        XCTAssertEqual(syncedEntry.syncState, .synced)
        XCTAssertEqual(syncedEntry.baselineUserData.playbackPositionSeconds, 0)
        let calls = await client.playedMutationCalls()
        XCTAssertEqual(calls.0, [])
        XCTAssertEqual(calls.1, ["ep-1"])
    }

    func testCacheDanmakuPayloadWritesOfflinePayloadFile() async throws {
        let mappingStore = DanmakuMatchMappingStore(
            snapshot: DanmakuMatchMappingSnapshot()
        )
        let danmakuStore = DanmakuFeatureStore(
            client: MockDandanplayClient(
                searchResults: [
                    AnimeSearchResult(
                        id: 100,
                        title: "Frieren",
                        typeDescription: "TV",
                        imageURL: nil,
                        episodeCount: 28
                    )
                ],
                episodesByAnimeID: [
                    100: [
                        AnimeEpisode(id: 2, number: 2, title: "魔法使い")
                    ]
                ],
                commentsByEpisodeID: [
                    2: [
                        DanmakuComment(
                            time: 1.0,
                            text: "cached",
                            presentation: .scroll,
                            color: .white
                        )
                    ]
                ]
            ),
            mappingStore: mappingStore
        )
        let store = makeStore(
            client: MockJellyfinClient(),
            danmakuPrefetchStore: danmakuStore
        )
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        let relativePath = await store.cacheDanmakuPayload(
            query: "Frieren",
            inferredSeasonNumber: 1,
            inferredEpisodeNumber: 2,
            remoteSeriesID: "series-1",
            remoteSeasonID: "season-1",
            remoteEpisodeID: "episode-2",
            to: cacheDirectory
        )

        let payloadURL = try XCTUnwrap(
            relativePath.map { cacheDirectory.appendingPathComponent($0) }
        )
        let payload = try JSONDecoder().decode(
            DanmakuOfflineCachePayload.self,
            from: Data(contentsOf: payloadURL)
        )
        let snapshot = await mappingStore.snapshotForTesting()

        XCTAssertEqual(relativePath, "danmaku.json")
        XCTAssertEqual(payload.anime.id, 100)
        XCTAssertEqual(payload.episode.id, 2)
        XCTAssertEqual(payload.comments.map(\.text), ["cached"])
        XCTAssertTrue(snapshot.animeMappings.isEmpty)
        XCTAssertTrue(snapshot.episodeMappings.isEmpty)
    }
}
