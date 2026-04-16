import XCTest
@testable import StarmineCore

actor MockJellyfinClient: JellyfinClientProtocol {
    let snapshotValue: JellyfinStoreSnapshot
    let librariesByAccountID: [UUID: [JellyfinLibrary]]
    let itemsByLibraryID: [String: [JellyfinMediaItem]]
    let seasonsBySeriesID: [String: [JellyfinSeason]]
    let episodesBySeasonID: [String: [JellyfinEpisode]]
    let adjacentEpisodesByEpisodeID: [String: [JellyfinEpisode]]
    let playbackSessionsByItemID: [String: JellyfinPlaybackSession]
    var lastRememberedLibraryID: String?

    init(
        snapshotValue: JellyfinStoreSnapshot = .init(accounts: [], activeAccountID: nil),
        librariesByAccountID: [UUID: [JellyfinLibrary]] = [:],
        itemsByLibraryID: [String: [JellyfinMediaItem]] = [:],
        seasonsBySeriesID: [String: [JellyfinSeason]] = [:],
        episodesBySeasonID: [String: [JellyfinEpisode]] = [:],
        adjacentEpisodesByEpisodeID: [String: [JellyfinEpisode]] = [:],
        playbackSessionsByItemID: [String: JellyfinPlaybackSession] = [:]
    ) {
        self.snapshotValue = snapshotValue
        self.librariesByAccountID = librariesByAccountID
        self.itemsByLibraryID = itemsByLibraryID
        self.seasonsBySeriesID = seasonsBySeriesID
        self.episodesBySeasonID = episodesBySeasonID
        self.adjacentEpisodesByEpisodeID = adjacentEpisodesByEpisodeID
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

    func createPlaybackSession(accountID: UUID, itemID: String, mediaSourceID: String?) async throws -> JellyfinPlaybackSession {
        playbackSessionsByItemID[itemID] ?? JellyfinPlaybackSession(
            itemID: itemID,
            mediaSourceID: mediaSourceID,
            playSessionID: nil,
            streamURL: URL(string: "http://example.com/\(itemID).mp4")!,
            mediaSources: []
        )
    }

    func rememberedLibraryID() async -> String? {
        lastRememberedLibraryID
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
}
