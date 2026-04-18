import Combine
import Foundation

struct JellyfinPlaybackCandidate: Hashable {
    var accountID: UUID
    var session: JellyfinPlaybackSession
    var itemKind: JellyfinItemKind
    var title: String
    var episodeLabel: String
    var collectionTitle: String?
    var danmakuQuery: String
    var remoteSeriesID: String?
    var remoteSeasonID: String?
    var remoteEpisodeID: String?
    var seasonNumber: Int?
    var seasonEpisodeCount: Int?
    var episodeNumber: Int?
    var resumePosition: Double?

    init(
        accountID: UUID = UUID(),
        session: JellyfinPlaybackSession,
        itemKind: JellyfinItemKind,
        title: String,
        episodeLabel: String,
        collectionTitle: String?,
        danmakuQuery: String,
        remoteSeriesID: String?,
        remoteSeasonID: String?,
        remoteEpisodeID: String?,
        seasonNumber: Int?,
        seasonEpisodeCount: Int?,
        episodeNumber: Int?,
        resumePosition: Double?
    ) {
        self.accountID = accountID
        self.session = session
        self.itemKind = itemKind
        self.title = title
        self.episodeLabel = episodeLabel
        self.collectionTitle = collectionTitle
        self.danmakuQuery = danmakuQuery
        self.remoteSeriesID = remoteSeriesID
        self.remoteSeasonID = remoteSeasonID
        self.remoteEpisodeID = remoteEpisodeID
        self.seasonNumber = seasonNumber
        self.seasonEpisodeCount = seasonEpisodeCount
        self.episodeNumber = episodeNumber
        self.resumePosition = resumePosition
    }
}

private struct JellyfinTrackedPlayback {
    var accountID: UUID
    var session: JellyfinPlaybackSession
    var itemKind: JellyfinItemKind
    var hasLoaded = false
    var lastReportedPosition = 0.0
    var lastReportedAt: Date?
    var lastPausedState: Bool?
}

private struct JellyfinTrackedOfflinePlayback {
    var entryID: UUID
    var hasLoaded = false
    var lastReportedPosition = 0.0
    var lastReportedAt: Date?
    var lastPausedState: Bool?
}

private enum JellyfinOfflineDownloadJobKind {
    case movie(item: JellyfinMediaItem)
    case episode(
        episode: JellyfinEpisode,
        series: JellyfinMediaItem?,
        season: JellyfinSeason?
    )
}

private struct JellyfinOfflineDownloadJob {
    var taskID: UUID
    var accountID: UUID
    var serverID: String
    var userID: String
    var accountDisplayTitle: String
    var libraryName: String?
    var kind: JellyfinOfflineDownloadJobKind
}

@MainActor
final class JellyfinStore: ObservableObject {
    private static let homeAccountDefaultsKey = "starmine.jellyfin.home-account"

    @Published var accounts: [JellyfinAccountProfile] = []
    @Published var selectedAccountID: UUID?
    @Published var homeAccountID: UUID?
    @Published var libraries: [JellyfinLibrary] = []
    @Published var selectedLibraryID: String?
    @Published var items: [JellyfinMediaItem] = []
    @Published var selectedItemID: String?
    @Published var seasons: [JellyfinSeason] = []
    @Published var selectedSeasonID: String?
    @Published var episodes: [JellyfinEpisode] = []
    @Published var selectedEpisodeID: String?
    @Published var resumeItems: [JellyfinHomeItem] = []
    @Published var recentItems: [JellyfinHomeItem] = []
    @Published var nextUpItems: [JellyfinHomeItem] = []
    @Published var recommendedItems: [JellyfinHomeItem] = []
    @Published var isLoading = false
    @Published var isRefreshingHome = false
    @Published var isConnecting = false
    @Published private(set) var updatingPlayedItemIDs: Set<String> = []
    @Published private(set) var isSyncingPlayback = false
    @Published private(set) var lastPlaybackSyncAt: Date?
    @Published private(set) var offlineEntries: [JellyfinOfflineEntry] = []
    @Published private(set) var offlineDownloadTasks:
        [JellyfinOfflineDownloadTask] = []
    @Published private(set) var isSyncingOfflineState = false

    private let client: any JellyfinClientProtocol
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let offlineRootURL: URL
    private let danmakuPrefetchStore: DanmakuFeatureStore
    private(set) var previousRemoteEpisode: JellyfinEpisode?
    private(set) var nextRemoteEpisode: JellyfinEpisode?
    private(set) var previousOfflineEntry: JellyfinOfflineEntry?
    private(set) var nextOfflineEntry: JellyfinOfflineEntry?
    private var activeTrackedPlayback: JellyfinTrackedPlayback?
    private var activeTrackedOfflinePlayback: JellyfinTrackedOfflinePlayback?
    private var selectedItemOverride: JellyfinMediaItem?
    private var pendingOfflineDownloadJobs: [JellyfinOfflineDownloadJob] = []
    private var activeOfflineDownloadJob: JellyfinOfflineDownloadJob?
    private var isProcessingOfflineDownloadQueue = false

    init(
        client: any JellyfinClientProtocol = JellyfinClient.shared,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        offlineRootURL: URL? = nil,
        danmakuPrefetchStore: DanmakuFeatureStore? = nil
    ) {
        self.client = client
        self.defaults = defaults
        self.fileManager = fileManager
        self.offlineRootURL =
            offlineRootURL
            ?? JellyfinStore.makeDefaultOfflineRootURL(fileManager: fileManager)
        self.danmakuPrefetchStore =
            danmakuPrefetchStore
            ?? DanmakuFeatureStore(userDefaults: defaults)
        loadOfflineEntries()
    }

    var activeAccount: JellyfinAccountProfile? {
        accounts.first(where: { $0.id == selectedAccountID })
    }

    var activeRoute: JellyfinRoute? {
        activeAccount?.activeRoute
    }

    var usesAutomaticRouteSelection: Bool {
        activeAccount?.usesAutomaticRouteSelection ?? true
    }

    var homeAccount: JellyfinAccountProfile? {
        accounts.first(where: { $0.id == homeAccountID })
    }

    var homeRoute: JellyfinRoute? {
        homeAccount?.activeRoute
    }

    var selectedLibrary: JellyfinLibrary? {
        libraries.first(where: { $0.id == selectedLibraryID })
    }

    var selectedItem: JellyfinMediaItem? {
        if let selectedItemID,
            let item = items.first(where: { $0.id == selectedItemID })
        {
            return item
        }
        return selectedItemOverride
    }

    var selectedSeason: JellyfinSeason? {
        seasons.first(where: { $0.id == selectedSeasonID })
    }

    var selectedEpisode: JellyfinEpisode? {
        episodes.first(where: { $0.id == selectedEpisodeID })
    }

    var canPlayPreviousEpisode: Bool {
        previousRemoteEpisode != nil || previousOfflineEntry != nil
    }

    var canPlayNextEpisode: Bool {
        nextRemoteEpisode != nil || nextOfflineEntry != nil
    }

    func restoreState() async throws {
        let snapshot = await client.snapshot()
        applySnapshot(snapshot)
        if selectedAccountID != nil {
            try await refreshLibrary()
        } else {
            clearBrowseState(clearLibraries: true)
        }
        if homeAccountID != nil {
            try await refreshHome()
        } else {
            clearHomeState()
        }
        await syncOfflineEntriesIfPossible()
    }

    func connect(
        serverURL: String,
        username: String,
        password: String,
        routeName: String?
    ) async throws {
        isConnecting = true
        defer { isConnecting = false }

        let snapshot = try await client.connect(
            serverURL: serverURL,
            username: username,
            password: password,
            routeName: routeName
        )
        applySnapshot(snapshot)
        clearBrowseState(clearLibraries: true)
        try await refreshLibrary()
        if homeAccountID != nil {
            try await refreshHome()
        } else {
            clearHomeState()
        }
        await syncOfflineEntriesIfPossible()
    }

    func addRoute(serverURL: String, routeName: String?) async throws {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }

        isConnecting = true
        defer { isConnecting = false }

        let snapshot = try await client.addRoute(
            accountID: accountID,
            serverURL: serverURL,
            routeName: routeName
        )
        applySnapshot(snapshot)
    }

    func switchAccount(_ accountID: UUID) async throws {
        let snapshot = try await client.setActiveAccount(accountID)
        applySnapshot(snapshot)
        clearBrowseState(clearLibraries: true)
        try await refreshLibrary()
        await syncOfflineEntriesIfPossible()
    }

    func selectHomeAccount(_ accountID: UUID) async throws {
        guard accounts.contains(where: { $0.id == accountID }) else {
            throw JellyfinClientError.accountNotFound
        }
        guard homeAccountID != accountID else { return }
        homeAccountID = accountID
        persistHomeAccountSelection()
        clearHomeShelves()
        try await refreshHome()
        await syncOfflineEntriesIfPossible()
    }

    func switchRoute(_ routeID: UUID) async throws {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }
        let snapshot = try await client.switchRoute(
            accountID: accountID,
            routeID: routeID
        )
        applySnapshot(snapshot)
        try await refreshContexts(
            for: accountID,
            reconcileRoutes: false
        )
        await syncOfflineEntriesIfPossible()
    }

    func useAutomaticRouteSelection() async throws {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }

        let snapshot = try await client.useAutomaticRouteSelection(
            accountID: accountID
        )
        applySnapshot(snapshot)
        try await refreshContexts(
            for: accountID,
            reconcileRoutes: false
        )
        await syncOfflineEntriesIfPossible()
    }

    func updateRoutePriority(_ routeID: UUID, priority: Int) async throws {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }

        let previousRouteID = activeRouteID(forAccountID: accountID)
        let snapshot = try await client.updateRoutePriority(
            accountID: accountID,
            routeID: routeID,
            priority: priority
        )
        applySnapshot(snapshot)
        if activeRouteID(forAccountID: accountID) != previousRouteID {
            try await refreshContexts(
                for: accountID,
                reconcileRoutes: false
            )
            await syncOfflineEntriesIfPossible()
        }
    }

    func refreshRoutesAfterAppBecomesActive() async throws {
        let currentBrowseAccountID = selectedAccountID
        let currentHomeAccountID = homeAccountID

        let browseRouteChanged =
            if let currentBrowseAccountID {
                await reconcileRoutesIfNeeded(
                    for: currentBrowseAccountID,
                    preservingSelectedAccountID: currentBrowseAccountID
                )
            } else {
                false
            }
        let homeRouteChanged =
            if let currentHomeAccountID {
                if currentHomeAccountID == currentBrowseAccountID {
                    browseRouteChanged
                } else {
                    await reconcileRoutesIfNeeded(
                        for: currentHomeAccountID,
                        preservingSelectedAccountID: currentBrowseAccountID
                    )
                }
            } else {
                false
            }

        if currentBrowseAccountID != nil,
            browseRouteChanged
                || (!libraries.isEmpty && items.isEmpty
                    && selectedLibraryID != nil)
        {
            try await refreshLibrary(reconcilingRoutes: false)
        }

        if currentHomeAccountID != nil,
            homeRouteChanged
                || (resumeItems.isEmpty
                    && recentItems.isEmpty
                    && nextUpItems.isEmpty
                    && recommendedItems.isEmpty)
        {
            try await refreshHome(reconcilingRoutes: false)
        }

        await syncOfflineEntriesIfPossible()
    }

    func removeSelectedAccount() async throws {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }
        try await removeAccount(accountID)
    }

    func removeAccount(_ accountID: UUID) async throws {
        let removedSelectedAccount = selectedAccountID == accountID
        let removedHomeAccount = homeAccountID == accountID
        let snapshot = try await client.removeAccount(accountID)
        applySnapshot(snapshot)

        guard removedSelectedAccount || removedHomeAccount else { return }

        if removedSelectedAccount {
            clearBrowseState(clearLibraries: selectedAccountID == nil)
            if selectedAccountID != nil {
                try await refreshLibrary()
            }
        }
        if homeAccountID != nil {
            try await refreshHome()
        } else {
            clearHomeState()
        }
        await syncOfflineEntriesIfPossible()
    }

    func refreshHome(reconcilingRoutes: Bool = true) async throws {
        guard let accountID = homeAccountID else {
            clearHomeState()
            return
        }
        let currentBrowseAccountID = selectedAccountID

        if reconcilingRoutes {
            _ = await reconcileRoutesIfNeeded(
                for: accountID,
                preservingSelectedAccountID: currentBrowseAccountID
            )
        }

        isRefreshingHome = true
        defer { isRefreshingHome = false }

        var errors: [Error] = []

        do {
            resumeItems = deduplicated(
                try await client.loadResumeItems(
                    accountID: accountID,
                    limit: 12
                )
            )
        } catch {
            resumeItems = []
            errors.append(error)
        }

        do {
            recentItems = deduplicated(
                try await client.loadRecentItems(
                    accountID: accountID,
                    limit: 12
                )
            )
        } catch {
            recentItems = []
            errors.append(error)
        }

        do {
            nextUpItems = deduplicated(
                try await client.loadNextUp(accountID: accountID, limit: 12)
            )
        } catch {
            nextUpItems = []
            errors.append(error)
        }

        do {
            let exclusions = Set(
                resumeItems.map(\.id) + nextUpItems.map(\.id)
                    + recentItems.map(\.id)
            )
            recommendedItems = deduplicated(
                try await client.loadRecommendedItems(
                    accountID: accountID,
                    limit: 12
                )
            )
            .filter { !exclusions.contains($0.id) }
        } catch {
            recommendedItems = []
            errors.append(error)
        }

        let snapshot = await client.snapshot()
        applySnapshot(
            snapshot,
            preservingSelectedAccountID: currentBrowseAccountID
        )

        if errors.count == 4, let firstError = errors.first {
            throw firstError
        }
    }

    func switchToHomeAccountForBrowsing() async throws -> UUID {
        guard let accountID = homeAccountID else {
            throw JellyfinClientError.accountNotFound
        }
        if selectedAccountID != accountID {
            try await switchAccount(accountID)
        }
        return accountID
    }

    func refreshLibrary(reconcilingRoutes: Bool = true) async throws {
        guard let accountID = selectedAccountID else {
            clearBrowseState(clearLibraries: true)
            return
        }

        if reconcilingRoutes {
            _ = await reconcileRoutesIfNeeded(
                for: accountID,
                preservingSelectedAccountID: accountID
            )
        }

        isLoading = true
        defer { isLoading = false }

        let libraries = try await client.loadLibraries(accountID: accountID)
        let snapshot = await client.snapshot()
        applySnapshot(snapshot)
        self.libraries = libraries

        let rememberedLibraryID = activeAccount?.lastSelectedLibraryID
        let resolvedLibraryID =
            selectedLibraryID.flatMap { currentID in
                libraries.contains(where: { $0.id == currentID })
                    ? currentID : nil
            } ?? rememberedLibraryID.flatMap { savedID in
                libraries.contains(where: { $0.id == savedID }) ? savedID : nil
            } ?? libraries.first?.id

        let updatedSnapshot = await client.rememberSelectedLibrary(
            accountID: accountID,
            libraryID: resolvedLibraryID
        )
        applySnapshot(updatedSnapshot)
        selectedLibraryID = resolvedLibraryID

        if let resolvedLibraryID {
            try await loadItems(for: resolvedLibraryID, accountID: accountID)
        } else {
            clearBrowseState(clearLibraries: false)
        }
        await syncOfflineEntriesIfPossible()
    }

    func selectLibrary(_ library: JellyfinLibrary) async throws {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }
        selectedLibraryID = library.id
        clearSelectionState()

        let snapshot = await client.rememberSelectedLibrary(
            accountID: accountID,
            libraryID: library.id
        )
        applySnapshot(snapshot)
        try await loadItems(for: library.id, accountID: accountID)
    }

    func selectItem(_ item: JellyfinMediaItem) async throws {
        selectedItemID = item.id
        selectedItemOverride = item
        selectedSeasonID = nil
        selectedEpisodeID = nil
        seasons = []
        episodes = []
        clearRemoteNavigation()

        if item.kind == .series {
            try await loadSeasons(for: item)
        }
    }

    func selectSeason(_ season: JellyfinSeason) async throws {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }
        selectedSeasonID = season.id
        selectedEpisodeID = nil
        clearRemoteNavigation()

        let seriesID = season.seriesID ?? selectedItemID ?? ""
        guard !seriesID.isEmpty else { return }
        episodes = try await client.loadEpisodes(
            accountID: accountID,
            seriesID: seriesID,
            seasonID: season.id
        )
        let snapshot = await client.snapshot()
        applySnapshot(snapshot)
    }

    func clearSelectedItem() {
        clearSelectionState()
    }

    func focusLibraryContext(for homeItem: JellyfinHomeItem) async throws {
        switch homeItem.kind {
        case .episode:
            guard let seriesID = homeItem.seriesID else {
                throw JellyfinClientError.requestFailed("无法定位对应剧集。")
            }

            var payload: [String: Any] = [
                "Id": seriesID,
                "Name": homeItem.seriesName ?? homeItem.name,
                "Type": "Series",
            ]
            if let overview = homeItem.overview?.nilIfBlank {
                payload["Overview"] = overview
            }
            if let imagePrimaryTag = homeItem.imagePrimaryTag {
                payload["ImageTags"] = ["Primary": imagePrimaryTag]
            }

            let seriesItem = JellyfinMediaItem(
                payload: payload
            )

            try await selectItem(seriesItem)

            let resolvedSeason =
                homeItem.seasonID.flatMap { seasonID in
                    seasons.first(where: { $0.id == seasonID })
                }
                ?? homeItem.parentIndexNumber.flatMap { seasonNumber in
                    seasons.first(where: { $0.indexNumber == seasonNumber })
                }

            if let resolvedSeason, selectedSeasonID != resolvedSeason.id {
                try await selectSeason(resolvedSeason)
            }

            if episodes.contains(where: { $0.id == homeItem.id }) {
                selectedEpisodeID = homeItem.id
            }

        case .series:
            try await selectItem(JellyfinMediaItem(homeItem: homeItem))

        case .movie, .video:
            selectedItemID = homeItem.id
            selectedItemOverride = JellyfinMediaItem(homeItem: homeItem)
            selectedSeasonID = nil
            selectedEpisodeID = nil
            seasons = []
            episodes = []
            clearRemoteNavigation()

        default:
            throw JellyfinClientError.requestFailed("该项目暂不支持定位到媒体库。")
        }
    }

    func setPlayedState(itemID: String, played: Bool) async throws {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }
        try await setPlayedState(
            itemID: itemID,
            played: played,
            accountID: accountID
        )
    }

    func setHomePlayedState(itemID: String, played: Bool) async throws {
        guard let accountID = homeAccountID else {
            throw JellyfinClientError.accountNotFound
        }
        try await setPlayedState(
            itemID: itemID,
            played: played,
            accountID: accountID
        )
    }

    private func setPlayedState(
        itemID: String,
        played: Bool,
        accountID: UUID
    ) async throws {
        updatingPlayedItemIDs.insert(itemID)
        defer {
            updatingPlayedItemIDs.remove(itemID)
        }

        if played {
            try await client.markPlayed(accountID: accountID, itemID: itemID)
        } else {
            try await client.markUnplayed(accountID: accountID, itemID: itemID)
        }

        applyPlayedStateLocally(
            itemID: itemID,
            played: played,
            accountID: accountID
        )

        if accountID == homeAccountID {
            do {
                try await refreshHome()
            } catch {
                // Keep local state if refreshing shelves fails.
            }
        }
    }

    func isUpdatingPlayedState(for itemID: String) -> Bool {
        updatingPlayedItemIDs.contains(itemID)
    }

    func makePlaybackCandidate(for item: JellyfinMediaItem) async throws
        -> JellyfinPlaybackCandidate
    {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }
        return try await makePlaybackCandidate(
            for: item,
            accountID: accountID,
            syncBrowseSelection: true
        )
    }

    private func makePlaybackCandidate(
        for item: JellyfinMediaItem,
        accountID: UUID,
        syncBrowseSelection: Bool
    ) async throws -> JellyfinPlaybackCandidate {
        let session = try await client.createPlaybackSession(
            accountID: accountID,
            itemID: item.id,
            mediaSourceID: nil
        )
        let snapshot = await client.snapshot()
        applySnapshot(snapshot)
        if syncBrowseSelection {
            selectedEpisodeID = nil
        }
        clearRemoteNavigation()

        return JellyfinPlaybackCandidate(
            accountID: accountID,
            session: session,
            itemKind: item.kind,
            title: item.name,
            episodeLabel: "",
            collectionTitle: nil,
            danmakuQuery: item.name,
            remoteSeriesID: nil,
            remoteSeasonID: nil,
            remoteEpisodeID: nil,
            seasonNumber: nil,
            seasonEpisodeCount: nil,
            episodeNumber: nil,
            resumePosition: item.resumePositionSeconds
        )
    }

    func makePlaybackCandidate(for episode: JellyfinEpisode) async throws
        -> JellyfinPlaybackCandidate
    {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }
        return try await makePlaybackCandidate(
            for: episode,
            accountID: accountID,
            syncBrowseSelection: true
        )
    }

    private func makePlaybackCandidate(
        for episode: JellyfinEpisode,
        accountID: UUID,
        syncBrowseSelection: Bool
    ) async throws -> JellyfinPlaybackCandidate {
        let session = try await client.createPlaybackSession(
            accountID: accountID,
            itemID: episode.id,
            mediaSourceID: nil
        )
        let snapshot = await client.snapshot()
        applySnapshot(snapshot)
        if syncBrowseSelection {
            selectedItemID = episode.seriesID ?? selectedItemID
            selectedEpisodeID = episode.id
        }

        await resolveRemoteEpisodeNeighbors(
            for: episode,
            accountID: accountID,
            preferredEpisodes: syncBrowseSelection ? episodes : nil
        )

        let seasonEpisodeCount =
            syncBrowseSelection
            ? episodes.filter {
                $0.danmakuEpisodeOrdinal != nil
            }.count
            : 0

        return JellyfinPlaybackCandidate(
            accountID: accountID,
            session: session,
            itemKind: .episode,
            title: episode.seriesName ?? episode.name,
            episodeLabel: episode.displayTitle,
            collectionTitle: episode.seriesName,
            danmakuQuery: episode.seriesName ?? episode.name,
            remoteSeriesID: episode.seriesID
                ?? (syncBrowseSelection ? selectedItemID : nil),
            remoteSeasonID: episode.seasonID,
            remoteEpisodeID: episode.id,
            seasonNumber: episode.parentIndexNumber,
            seasonEpisodeCount: seasonEpisodeCount > 0
                ? seasonEpisodeCount : nil,
            episodeNumber: episode.danmakuEpisodeOrdinal,
            resumePosition: episode.resumePositionSeconds
        )
    }

    func makePlaybackCandidate(for homeItem: JellyfinHomeItem) async throws
        -> JellyfinPlaybackCandidate
    {
        guard let accountID = homeAccountID else {
            throw JellyfinClientError.accountNotFound
        }

        switch homeItem.kind {
        case .episode:
            return try await makePlaybackCandidate(
                for: episodeCandidate(from: homeItem),
                accountID: accountID,
                syncBrowseSelection: accountID == selectedAccountID
            )
        case .movie, .video:
            return try await makePlaybackCandidate(
                for: JellyfinMediaItem(homeItem: homeItem),
                accountID: accountID,
                syncBrowseSelection: accountID == selectedAccountID
            )
        default:
            throw JellyfinClientError.requestFailed("该项目不可直接播放。")
        }
    }

    func beginPlaybackTracking(
        candidate: JellyfinPlaybackCandidate,
        initialPosition: Double = 0,
        isPaused: Bool = false
    ) async {
        activeTrackedPlayback = JellyfinTrackedPlayback(
            accountID: candidate.accountID,
            session: candidate.session,
            itemKind: candidate.itemKind
        )
        isSyncingPlayback = true
        applyPlaybackProgressLocally(
            accountID: candidate.accountID,
            itemID: candidate.session.itemID,
            positionSeconds: max(
                initialPosition,
                candidate.resumePosition ?? 0
            ),
            finished: false
        )

        do {
            try await client.reportPlaybackStarted(
                accountID: candidate.accountID,
                session: candidate.session,
                positionSeconds: initialPosition,
                isPaused: isPaused
            )
            if var tracked = activeTrackedPlayback,
                tracked.session.itemID == candidate.session.itemID
            {
                tracked.lastReportedAt = Date()
                tracked.lastReportedPosition = max(0, initialPosition)
                tracked.lastPausedState = isPaused
                activeTrackedPlayback = tracked
            }
            lastPlaybackSyncAt = Date()
        } catch {
            // Keep local state and retry on the next progress pulse.
        }
    }

    func markActivePlaybackLoaded() {
        guard var tracked = activeTrackedPlayback else { return }
        tracked.hasLoaded = true
        activeTrackedPlayback = tracked
    }

    var hasLoadedActivePlayback: Bool {
        activeTrackedPlayback?.hasLoaded ?? false
    }

    func reportActivePlaybackProgress(
        positionSeconds: Double,
        durationSeconds: Double,
        isPaused: Bool,
        force: Bool = false
    ) async {
        guard var tracked = activeTrackedPlayback else { return }

        let clampedPosition = clampedPlaybackPosition(
            positionSeconds,
            durationSeconds: durationSeconds
        )
        let now = Date()
        let pauseChanged = tracked.lastPausedState != isPaused
        let timeDelta =
            tracked.lastReportedAt.map { now.timeIntervalSince($0) }
            ?? .greatestFiniteMagnitude
        let positionDelta = abs(clampedPosition - tracked.lastReportedPosition)

        applyPlaybackProgressLocally(
            accountID: tracked.accountID,
            itemID: tracked.session.itemID,
            positionSeconds: clampedPosition,
            finished: false
        )

        guard force || pauseChanged || timeDelta >= 10 || positionDelta >= 15
        else {
            return
        }

        do {
            try await client.reportPlaybackProgress(
                accountID: tracked.accountID,
                session: tracked.session,
                positionSeconds: clampedPosition,
                isPaused: isPaused
            )
            tracked.lastReportedAt = now
            tracked.lastReportedPosition = clampedPosition
            tracked.lastPausedState = isPaused
            activeTrackedPlayback = tracked
            lastPlaybackSyncAt = now
        } catch {
            // Retry on the next forced or periodic sync.
        }
    }

    func finishPlaybackTracking(
        positionSeconds: Double,
        durationSeconds: Double,
        isPaused: Bool,
        finished: Bool
    ) async {
        guard let tracked = activeTrackedPlayback else { return }
        let clampedPosition = clampedPlaybackPosition(
            positionSeconds,
            durationSeconds: durationSeconds
        )

        applyPlaybackProgressLocally(
            accountID: tracked.accountID,
            itemID: tracked.session.itemID,
            positionSeconds: clampedPosition,
            finished: finished
        )

        do {
            try await client.reportPlaybackStopped(
                accountID: tracked.accountID,
                session: tracked.session,
                positionSeconds: clampedPosition,
                isPaused: isPaused,
                finished: finished
            )
            lastPlaybackSyncAt = Date()
        } catch {
            // Keep the UI responsive even if the final sync fails.
        }

        activeTrackedPlayback = nil
        isSyncingPlayback = false

        if tracked.accountID == homeAccountID {
            do {
                try await refreshHome()
            } catch {
                // Preserve the last known shelves when refresh fails.
            }
        }
    }

    func cancelPlaybackTracking() {
        activeTrackedPlayback = nil
        isSyncingPlayback = false
    }

    func clearRemoteNavigation() {
        previousRemoteEpisode = nil
        nextRemoteEpisode = nil
    }

    func jellyfinLibraryImageURL(
        _ library: JellyfinLibrary,
        width: Int = 320,
        height: Int = 190
    ) -> URL? {
        imageURL(
            itemID: library.id,
            imageType: "Primary",
            tag: library.imageTag,
            width: width,
            height: height
        )
    }

    func jellyfinPosterURL(
        for item: JellyfinMediaItem,
        width: Int = 440,
        height: Int = 660
    ) -> URL? {
        imageURL(
            itemID: item.id,
            imageType: "Primary",
            tag: item.imagePrimaryTag,
            width: width,
            height: height
        )
    }

    func jellyfinBackdropURL(
        for item: JellyfinMediaItem,
        width: Int = 1400,
        height: Int = 700
    ) -> URL? {
        imageURL(
            itemID: item.id,
            imageType: "Backdrop",
            tag: item.imageBackdropTag,
            width: width,
            height: height,
            index: 0
        )
    }

    func jellyfinPosterURL(
        for season: JellyfinSeason,
        width: Int = 320,
        height: Int = 480
    ) -> URL? {
        imageURL(
            itemID: season.id,
            imageType: "Primary",
            tag: season.imagePrimaryTag,
            width: width,
            height: height
        )
    }

    func jellyfinPosterURL(
        for homeItem: JellyfinHomeItem,
        width: Int = 440,
        height: Int = 660
    ) -> URL? {
        imageURL(
            accountID: homeAccountID,
            itemID: homeItem.id,
            imageType: "Primary",
            tag: homeItem.imagePrimaryTag,
            width: width,
            height: height
        )
    }

    func jellyfinBackdropURL(
        for homeItem: JellyfinHomeItem,
        width: Int = 1400,
        height: Int = 700
    ) -> URL? {
        imageURL(
            accountID: homeAccountID,
            itemID: homeItem.id,
            imageType: "Backdrop",
            tag: homeItem.imageBackdropTag,
            width: width,
            height: height,
            index: 0
        )
    }

    func jellyfinEpisodeThumbnailURL(
        _ episode: JellyfinEpisode,
        width: Int = 480,
        height: Int = 270
    ) -> URL? {
        imageURL(
            itemID: episode.id,
            imageType: "Primary",
            tag: episode.imagePrimaryTag,
            width: width,
            height: height
        )
    }

    private func applySnapshot(
        _ snapshot: JellyfinStoreSnapshot,
        preservingSelectedAccountID preferredSelectedAccountID: UUID? = nil
    ) {
        accounts = snapshot.accounts
        let resolvedSelectedAccountID =
            preferredSelectedAccountID.flatMap { preferredID in
                snapshot.accounts.contains(where: { $0.id == preferredID })
                    ? preferredID : nil
            }
            ?? snapshot.activeAccountID.flatMap { activeID in
                snapshot.accounts.contains(where: { $0.id == activeID })
                    ? activeID : nil
            }
            ?? snapshot.accounts.first?.id
        selectedAccountID = resolvedSelectedAccountID

        let persistedHomeAccountID =
            defaults.string(forKey: Self.homeAccountDefaultsKey)
            .flatMap(UUID.init(uuidString:))
        let resolvedHomeAccountID =
            homeAccountID.flatMap { currentID in
                snapshot.accounts.contains(where: { $0.id == currentID })
                    ? currentID : nil
            }
            ?? persistedHomeAccountID.flatMap { savedID in
                snapshot.accounts.contains(where: { $0.id == savedID })
                    ? savedID : nil
            }
            ?? selectedAccountID
            ?? snapshot.accounts.first?.id
        homeAccountID = resolvedHomeAccountID
        persistHomeAccountSelection()
    }

    private func clearSelectionState() {
        selectedItemID = nil
        selectedItemOverride = nil
        selectedSeasonID = nil
        selectedEpisodeID = nil
        seasons = []
        episodes = []
        clearRemoteNavigation()
    }

    private func clearBrowseState(clearLibraries: Bool) {
        if clearLibraries {
            libraries = []
            selectedLibraryID = nil
        }
        items = []
        clearSelectionState()
    }

    private func clearHomeState() {
        clearHomeShelves()
        cancelPlaybackTracking()
    }

    private func clearHomeShelves() {
        resumeItems = []
        recentItems = []
        nextUpItems = []
        recommendedItems = []
    }

    private func imageURL(
        accountID: UUID? = nil,
        itemID: String,
        imageType: String,
        tag: String?,
        width: Int?,
        height: Int?,
        index: Int? = nil,
        quality: Int = 90
    ) -> URL? {
        let resolvedAccountID = accountID ?? selectedAccountID
        guard
            let resolvedAccountID,
            let account = accounts.first(where: { $0.id == resolvedAccountID }),
            let route = account.activeRoute
        else {
            return nil
        }

        var path = "/Items/\(itemID)/Images/\(imageType)"
        if imageType.caseInsensitiveCompare("Backdrop") == .orderedSame {
            path += "/\(index ?? 0)"
        }

        guard
            var components = URLComponents(
                string: "\(route.normalizedURL)\(path)"
            )
        else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "api_key", value: account.accessToken),
            URLQueryItem(name: "quality", value: String(quality)),
            width.map { URLQueryItem(name: "maxWidth", value: String($0)) },
            height.map { URLQueryItem(name: "maxHeight", value: String($0)) },
            tag.map { URLQueryItem(name: "tag", value: $0) },
        ].compactMap { $0 }

        return components.url
    }

    private func activeRouteID(forAccountID accountID: UUID?) -> UUID? {
        guard let accountID else { return nil }
        return accounts.first(where: { $0.id == accountID })?.activeRoute?.id
    }

    private func reconcileRoutesIfNeeded(
        for accountID: UUID,
        preservingSelectedAccountID preferredSelectedAccountID: UUID? = nil
    ) async -> Bool {
        let previousRouteID = activeRouteID(forAccountID: accountID)
        let snapshot = await client.reconcileRoutes(accountID: accountID)
        applySnapshot(
            snapshot,
            preservingSelectedAccountID: preferredSelectedAccountID
        )
        return previousRouteID != activeRouteID(forAccountID: accountID)
    }

    private func refreshContexts(
        for accountID: UUID,
        reconcileRoutes: Bool
    ) async throws {
        if selectedAccountID == accountID {
            try await refreshLibrary(reconcilingRoutes: reconcileRoutes)
        }
        if homeAccountID == accountID {
            try await refreshHome(reconcilingRoutes: reconcileRoutes)
        }
    }

    private func loadItems(for libraryID: String, accountID: UUID) async throws
    {
        items = try await client.loadLibraryItems(
            accountID: accountID,
            libraryID: libraryID
        )
        clearSelectionState()
        let snapshot = await client.snapshot()
        applySnapshot(snapshot)
    }

    private func loadSeasons(for item: JellyfinMediaItem) async throws {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }

        seasons = try await client.loadSeasons(
            accountID: accountID,
            seriesID: item.id
        )
        let snapshot = await client.snapshot()
        applySnapshot(snapshot)
        if let firstSeason = seasons.first {
            selectedSeasonID = firstSeason.id
            episodes = try await client.loadEpisodes(
                accountID: accountID,
                seriesID: item.id,
                seasonID: firstSeason.id
            )
        } else {
            episodes = []
        }
    }

    private func episodeCandidate(from homeItem: JellyfinHomeItem)
        -> JellyfinEpisode
    {
        JellyfinEpisode(homeItem: homeItem)
    }

    private func clampedPlaybackPosition(
        _ positionSeconds: Double,
        durationSeconds: Double
    ) -> Double {
        guard durationSeconds > 0 else {
            return max(0, positionSeconds)
        }
        return min(durationSeconds, max(0, positionSeconds))
    }

    private func deduplicated(_ items: [JellyfinHomeItem]) -> [JellyfinHomeItem]
    {
        var seen = Set<String>()
        return items.filter { item in
            seen.insert(item.id).inserted
        }
    }

    private func persistHomeAccountSelection() {
        defaults.set(
            homeAccountID?.uuidString,
            forKey: Self.homeAccountDefaultsKey
        )
    }

    private func applyPlaybackProgressLocally(
        accountID: UUID,
        itemID: String,
        positionSeconds: Double,
        finished: Bool
    ) {
        let shouldUpdateBrowseContext = accountID == selectedAccountID
        let shouldUpdateHomeContext = accountID == homeAccountID

        if shouldUpdateBrowseContext {
            items = items.map { item in
                guard item.id == itemID else { return item }
                var updated = item
                updated.userData = updatedUserData(
                    from: item.userData,
                    positionSeconds: positionSeconds,
                    finished: finished
                )
                return updated
            }
        }

        if shouldUpdateBrowseContext,
            var selectedItemOverrideCopy = selectedItemOverride,
            selectedItemOverrideCopy.id == itemID
        {
            let currentUserData = selectedItemOverrideCopy.userData
            selectedItemOverrideCopy.userData = updatedUserData(
                from: currentUserData,
                positionSeconds: positionSeconds,
                finished: finished
            )
            selectedItemOverride = selectedItemOverrideCopy
        }

        if shouldUpdateBrowseContext {
            episodes = episodes.map { episode in
                guard episode.id == itemID else { return episode }
                var updated = episode
                updated.userData = updatedUserData(
                    from: episode.userData,
                    positionSeconds: positionSeconds,
                    finished: finished
                )
                return updated
            }
        }

        if shouldUpdateHomeContext {
            resumeItems = updatedHomeSection(
                resumeItems,
                itemID: itemID,
                positionSeconds: positionSeconds,
                finished: finished,
                insertsIfMissing: !finished && positionSeconds > 15,
                prefersFrontInsertion: true,
                canUseBrowseContext: shouldUpdateBrowseContext
            )
            recentItems = updatedHomeSection(
                recentItems,
                itemID: itemID,
                positionSeconds: positionSeconds,
                finished: finished,
                insertsIfMissing: positionSeconds > 5,
                prefersFrontInsertion: true,
                canUseBrowseContext: shouldUpdateBrowseContext
            )
            nextUpItems = updatedHomeSection(
                nextUpItems,
                itemID: itemID,
                positionSeconds: positionSeconds,
                finished: finished,
                insertsIfMissing: false,
                prefersFrontInsertion: false,
                canUseBrowseContext: shouldUpdateBrowseContext
            )
            recommendedItems = updatedHomeSection(
                recommendedItems,
                itemID: itemID,
                positionSeconds: positionSeconds,
                finished: finished,
                insertsIfMissing: false,
                prefersFrontInsertion: false,
                canUseBrowseContext: shouldUpdateBrowseContext
            )
        }
    }

    private func updatedHomeSection(
        _ items: [JellyfinHomeItem],
        itemID: String,
        positionSeconds: Double,
        finished: Bool,
        insertsIfMissing: Bool,
        prefersFrontInsertion: Bool,
        canUseBrowseContext: Bool
    ) -> [JellyfinHomeItem] {
        var updatedItems = items
        let now = Date()

        if let index = updatedItems.firstIndex(where: { $0.id == itemID }) {
            if finished {
                updatedItems.remove(at: index)
                return updatedItems
            }

            var updated = updatedItems[index]
            updated.userData = updatedUserData(
                from: updated.userData,
                positionSeconds: positionSeconds,
                finished: false,
                playedAt: now
            )
            updatedItems[index] = updated
            if prefersFrontInsertion, index != 0 {
                let moved = updatedItems.remove(at: index)
                updatedItems.insert(moved, at: 0)
            }
            return updatedItems
        }

        guard
            insertsIfMissing,
            !finished,
            var seed = knownHomeItem(
                for: itemID,
                canUseBrowseContext: canUseBrowseContext
            )
        else {
            return updatedItems
        }

        seed.userData = updatedUserData(
            from: seed.userData,
            positionSeconds: positionSeconds,
            finished: false,
            playedAt: now
        )
        if prefersFrontInsertion {
            updatedItems.insert(seed, at: 0)
        } else {
            updatedItems.append(seed)
        }
        return deduplicated(updatedItems)
    }

    private func knownHomeItem(
        for itemID: String,
        canUseBrowseContext: Bool
    ) -> JellyfinHomeItem? {
        let homeScopedItem =
            resumeItems.first(where: { $0.id == itemID })
            ?? recentItems.first(where: { $0.id == itemID })
            ?? nextUpItems.first(where: { $0.id == itemID })
            ?? recommendedItems.first(where: { $0.id == itemID })
        guard homeScopedItem == nil, canUseBrowseContext else {
            return homeScopedItem
        }

        return items.first(where: { $0.id == itemID }).map(
            JellyfinHomeItem.init(mediaItem:)
        )
            ?? episodes.first(where: { $0.id == itemID }).map(
                JellyfinHomeItem.init(episode:)
            )
    }

    private func applyPlayedStateLocally(
        itemID: String,
        played: Bool,
        accountID: UUID
    ) {
        let shouldUpdateBrowseContext = accountID == selectedAccountID
        let shouldUpdateHomeContext = accountID == homeAccountID

        if shouldUpdateBrowseContext {
            items = items.map { item in
                guard item.id == itemID else { return item }
                var updated = item
                updated.userData = updatedPlayedUserData(
                    from: item.userData,
                    played: played
                )
                return updated
            }
        }

        if shouldUpdateBrowseContext,
            var selectedItemOverrideCopy = selectedItemOverride,
            selectedItemOverrideCopy.id == itemID
        {
            let currentUserData = selectedItemOverrideCopy.userData
            selectedItemOverrideCopy.userData = updatedPlayedUserData(
                from: currentUserData,
                played: played
            )
            selectedItemOverride = selectedItemOverrideCopy
        }

        if shouldUpdateBrowseContext {
            episodes = episodes.map { episode in
                guard episode.id == itemID else { return episode }
                var updated = episode
                updated.userData = updatedPlayedUserData(
                    from: episode.userData,
                    played: played
                )
                return updated
            }
        }

        if shouldUpdateHomeContext {
            resumeItems = updatedPlayedHomeSection(
                resumeItems,
                itemID: itemID,
                played: played,
                removeWhenPlayed: true
            )
            recentItems = updatedPlayedHomeSection(
                recentItems,
                itemID: itemID,
                played: played,
                removeWhenPlayed: false
            )
            nextUpItems = updatedPlayedHomeSection(
                nextUpItems,
                itemID: itemID,
                played: played,
                removeWhenPlayed: played
            )
            recommendedItems = updatedPlayedHomeSection(
                recommendedItems,
                itemID: itemID,
                played: played,
                removeWhenPlayed: false
            )
        }
    }

    private func resolveRemoteEpisodeNeighbors(
        for episode: JellyfinEpisode,
        accountID: UUID,
        preferredEpisodes: [JellyfinEpisode]? = nil
    ) async {
        previousRemoteEpisode = nil
        nextRemoteEpisode = nil

        if let preferredEpisodes,
            let index = preferredEpisodes.firstIndex(where: {
                $0.id == episode.id
            }
            )
        {
            if index > 0 {
                previousRemoteEpisode = preferredEpisodes[index - 1]
            }
            if preferredEpisodes.indices.contains(index + 1) {
                nextRemoteEpisode = preferredEpisodes[index + 1]
            }
        }

        if previousRemoteEpisode != nil && nextRemoteEpisode != nil {
            return
        }

        do {
            let adjacentEpisodes = try await client.loadAdjacentEpisodes(
                accountID: accountID,
                episodeID: episode.id
            )
            if let currentIndex = adjacentEpisodes.firstIndex(where: {
                $0.id == episode.id
            }) {
                if previousRemoteEpisode == nil, currentIndex > 0 {
                    previousRemoteEpisode = adjacentEpisodes[currentIndex - 1]
                }
                if nextRemoteEpisode == nil,
                    adjacentEpisodes.indices.contains(currentIndex + 1)
                {
                    nextRemoteEpisode = adjacentEpisodes[currentIndex + 1]
                }
            }
            let snapshot = await client.snapshot()
            applySnapshot(snapshot)
        } catch {
            // Keep season-local navigation if adjacent lookup fails.
        }
    }

    private func updatedPlayedHomeSection(
        _ items: [JellyfinHomeItem],
        itemID: String,
        played: Bool,
        removeWhenPlayed: Bool
    ) -> [JellyfinHomeItem] {
        if removeWhenPlayed, played {
            return items.filter { $0.id != itemID }
        }

        return items.map { item in
            guard item.id == itemID else { return item }
            var updated = item
            updated.userData = updatedPlayedUserData(
                from: item.userData,
                played: played
            )
            return updated
        }
    }

    private func updatedPlayedUserData(
        from userData: JellyfinUserData?,
        played: Bool
    ) -> JellyfinUserData {
        var updated = userData ?? JellyfinUserData()
        updated.played = played
        updated.playbackPositionTicks = 0
        updated.playCount = played ? max(updated.playCount ?? 0, 1) : 0
        updated.lastPlayedDate = Date()
        return updated
    }

    private func updatedUserData(
        from userData: JellyfinUserData?,
        positionSeconds: Double,
        finished: Bool,
        playedAt: Date = Date()
    ) -> JellyfinUserData {
        var updated = userData ?? JellyfinUserData()
        updated.played = finished ? true : false
        updated.playbackPositionTicks =
            finished ? 0 : positionSeconds * 10_000_000.0
        updated.lastPlayedDate = playedAt
        return updated
    }
}

@MainActor
extension JellyfinStore {
    var offlineDownloadedCount: Int {
        offlineEntries.count
    }

    var pendingOfflineSyncCount: Int {
        offlineEntries.filter {
            $0.syncState == .pendingUpload || $0.syncState == .failed
        }.count
    }

    var offlineConflictCount: Int {
        offlineEntries.filter { $0.syncState == .conflict }.count
    }

    var hasActiveOfflinePlayback: Bool {
        activeTrackedOfflinePlayback != nil
    }

    var activeOfflineEntry: JellyfinOfflineEntry? {
        guard let entryID = activeTrackedOfflinePlayback?.entryID else {
            return nil
        }
        return offlineEntries.first(where: { $0.id == entryID })
    }

    func offlineEntry(
        forRemoteItemID remoteItemID: String,
        accountID: UUID?
    ) -> JellyfinOfflineEntry? {
        offlineEntries.first { entry in
            entry.remoteItemID == remoteItemID
                && entryMatchesAccount(entry, accountID: accountID)
        }
    }

    func offlineEpisodeCount(forSeriesID seriesID: String, accountID: UUID?)
        -> Int
    {
        offlineEntries.filter { entry in
            entry.seriesID == seriesID
                && entryMatchesAccount(entry, accountID: accountID)
        }.count
    }

    func isDownloadingOfflineItem(_ remoteItemID: String) -> Bool {
        offlineDownloadTasks.contains(where: {
            $0.remoteItemID == remoteItemID && $0.phase != .failed
        })
    }

    func localVideoURL(for entry: JellyfinOfflineEntry) -> URL? {
        resolvedOfflineFileURL(relativePath: entry.videoRelativePath)
    }

    func localSubtitleURLs(for entry: JellyfinOfflineEntry) -> [URL] {
        entry.subtitles.compactMap { subtitle in
            resolvedOfflineFileURL(relativePath: subtitle.relativePath)
        }
    }

    func localDanmakuURL(for entry: JellyfinOfflineEntry) -> URL? {
        resolvedOfflineFileURL(relativePath: entry.danmakuRelativePath)
    }

    func localArtworkURL(for entry: JellyfinOfflineEntry) -> URL? {
        resolvedOfflineFileURL(
            relativePath: entry.thumbnailRelativePath
                ?? entry.posterRelativePath
                ?? entry.seasonPosterRelativePath
                ?? entry.backdropRelativePath
        )
    }

    private func entryMatchesAccount(
        _ entry: JellyfinOfflineEntry,
        accountID: UUID?
    ) -> Bool {
        guard let accountID,
            let account = accounts.first(where: { $0.id == accountID })
        else {
            return false
        }
        return entry.serverID == account.serverID
            && entry.userID == account.userID
    }

    func beginOfflinePlaybackTracking(entry: JellyfinOfflineEntry) {
        activeTrackedOfflinePlayback = JellyfinTrackedOfflinePlayback(
            entryID: entry.id
        )
        clearRemoteNavigation()
        resolveOfflineNavigation(for: entry)
    }

    func markActiveOfflinePlaybackLoaded() {
        guard var tracked = activeTrackedOfflinePlayback else { return }
        tracked.hasLoaded = true
        activeTrackedOfflinePlayback = tracked
    }

    var hasLoadedActiveOfflinePlayback: Bool {
        activeTrackedOfflinePlayback?.hasLoaded ?? false
    }

    func reportActiveOfflinePlaybackProgress(
        positionSeconds: Double,
        durationSeconds: Double,
        isPaused: Bool,
        force: Bool = false
    ) async {
        guard var tracked = activeTrackedOfflinePlayback else { return }
        let clampedPosition = clampedPlaybackPosition(
            positionSeconds,
            durationSeconds: durationSeconds
        )
        let now = Date()
        let pauseChanged = tracked.lastPausedState != isPaused
        let timeDelta =
            tracked.lastReportedAt.map { now.timeIntervalSince($0) }
            ?? .greatestFiniteMagnitude
        let positionDelta = abs(clampedPosition - tracked.lastReportedPosition)

        applyOfflinePlaybackProgressLocally(
            entryID: tracked.entryID,
            positionSeconds: clampedPosition,
            finished: false,
            playedAt: now
        )

        guard force || pauseChanged || timeDelta >= 10 || positionDelta >= 15
        else {
            return
        }

        tracked.lastReportedAt = now
        tracked.lastReportedPosition = clampedPosition
        tracked.lastPausedState = isPaused
        activeTrackedOfflinePlayback = tracked
    }

    func finishOfflinePlaybackTracking(
        positionSeconds: Double,
        durationSeconds: Double,
        isPaused _: Bool,
        finished: Bool
    ) {
        guard let tracked = activeTrackedOfflinePlayback else { return }
        let clampedPosition = clampedPlaybackPosition(
            positionSeconds,
            durationSeconds: durationSeconds
        )
        applyOfflinePlaybackProgressLocally(
            entryID: tracked.entryID,
            positionSeconds: clampedPosition,
            finished: finished
        )
        activeTrackedOfflinePlayback = nil
        clearOfflineNavigation()
    }

    func cancelOfflinePlaybackTracking() {
        activeTrackedOfflinePlayback = nil
        clearOfflineNavigation()
    }

    func setOfflinePlayedState(entryID: UUID, played: Bool) {
        guard let index = offlineEntries.firstIndex(where: { $0.id == entryID })
        else {
            return
        }
        var entry = offlineEntries[index]
        entry.localUserData = updatedPlayedUserData(
            from: entry.localUserData,
            played: played
        )
        markOfflineEntryForLocalChange(&entry, playedAt: Date())
        offlineEntries[index] = entry
        saveOfflineEntries()
    }

    func deleteOfflineEntry(_ entryID: UUID) {
        guard let index = offlineEntries.firstIndex(where: { $0.id == entryID })
        else {
            return
        }
        if activeTrackedOfflinePlayback?.entryID == entryID {
            cancelOfflinePlaybackTracking()
        }
        let entry = offlineEntries.remove(at: index)
        try? fileManager.removeItem(at: entryDirectoryURL(for: entry.id))
        refreshOfflineNavigationForActivePlaybackIfNeeded()
        saveOfflineEntries()
    }

    func dismissOfflineDownloadTask(_ taskID: UUID) {
        offlineDownloadTasks.removeAll(where: { $0.id == taskID })
    }

    func queueDownload(for item: JellyfinMediaItem) async throws {
        guard let account = activeAccount else {
            throw JellyfinClientError.accountNotFound
        }

        switch item.kind {
        case .movie, .video:
            enqueueOfflineDownloadJob(
                JellyfinOfflineDownloadJob(
                    taskID: UUID(),
                    accountID: account.id,
                    serverID: account.serverID,
                    userID: account.userID,
                    accountDisplayTitle: account.displayTitle,
                    libraryName: selectedLibrary?.name,
                    kind: .movie(item: item)
                ),
                remoteItemID: item.id,
                title: item.name,
                detailTitle: item.metaLine.nilIfBlank ?? item.kind.displayName,
                itemKind: item.kind
            )
        case .series:
            try await queueDownloadForSeries(item, account: account)
        default:
            throw JellyfinClientError.requestFailed("该项目暂不支持下载。")
        }
    }

    func queueDownload(
        for season: JellyfinSeason,
        in series: JellyfinMediaItem
    ) async throws {
        guard let account = activeAccount else {
            throw JellyfinClientError.accountNotFound
        }
        let seasonEpisodes =
            selectedSeasonID == season.id && !episodes.isEmpty
            ? episodes
            : try await client.loadEpisodes(
                accountID: account.id,
                seriesID: series.id,
                seasonID: season.id
            )
        try await queueDownload(
            for: seasonEpisodes,
            in: series,
            season: season,
            account: account
        )
    }

    func queueDownload(
        for selectedEpisodes: [JellyfinEpisode],
        in series: JellyfinMediaItem,
        season: JellyfinSeason?
    ) async throws {
        guard let account = activeAccount else {
            throw JellyfinClientError.accountNotFound
        }
        try await queueDownload(
            for: selectedEpisodes,
            in: series,
            season: season,
            account: account
        )
    }

    func queueDownload(for homeItem: JellyfinHomeItem) async throws {
        guard let account = homeAccount else {
            throw JellyfinClientError.accountNotFound
        }
        switch homeItem.kind {
        case .movie, .video:
            enqueueOfflineDownloadJob(
                JellyfinOfflineDownloadJob(
                    taskID: UUID(),
                    accountID: account.id,
                    serverID: account.serverID,
                    userID: account.userID,
                    accountDisplayTitle: account.displayTitle,
                    libraryName: nil,
                    kind: .movie(item: JellyfinMediaItem(homeItem: homeItem))
                ),
                remoteItemID: homeItem.id,
                title: homeItem.displayTitle,
                detailTitle: homeItem.detailTitle,
                itemKind: homeItem.kind
            )
        case .series:
            try await queueDownloadForSeries(
                JellyfinMediaItem(homeItem: homeItem),
                account: account
            )
        case .episode:
            let seriesItem = homeItem.seriesID.map { seriesID in
                JellyfinMediaItem(
                    payload: [
                        "Id": seriesID,
                        "Name": homeItem.seriesName ?? homeItem.displayTitle,
                        "Type": "Series",
                        "ImageTags": homeItem.imagePrimaryTag.map {
                            ["Primary": $0]
                        } as Any,
                        "BackdropImageTags": homeItem.imageBackdropTag.map {
                            [$0]
                        } as Any,
                    ].compactMapValues { $0 }
                )
            }
            let season = homeItem.seasonID.map { seasonID in
                JellyfinSeason(
                    payload: [
                        "Id": seasonID,
                        "Name": homeItem.seasonName ?? "季度",
                        "SeriesId": homeItem.seriesID as Any,
                        "SeriesName": homeItem.seriesName as Any,
                        "IndexNumber": homeItem.parentIndexNumber as Any,
                    ].compactMapValues { $0 }
                )
            }
            enqueueOfflineDownloadJob(
                JellyfinOfflineDownloadJob(
                    taskID: UUID(),
                    accountID: account.id,
                    serverID: account.serverID,
                    userID: account.userID,
                    accountDisplayTitle: account.displayTitle,
                    libraryName: nil,
                    kind: .episode(
                        episode: JellyfinEpisode(homeItem: homeItem),
                        series: seriesItem,
                        season: season
                    )
                ),
                remoteItemID: homeItem.id,
                title: homeItem.displayTitle,
                detailTitle: homeItem.detailTitle,
                itemKind: .episode
            )
        default:
            throw JellyfinClientError.requestFailed("该项目暂不支持下载。")
        }
    }

    func syncOfflineEntriesIfPossible() async {
        guard !isSyncingOfflineState else { return }
        let eligibleEntries = offlineEntries.filter {
            matchingAccount(for: $0) != nil
        }
        guard !eligibleEntries.isEmpty else { return }

        isSyncingOfflineState = true
        defer {
            isSyncingOfflineState = false
            saveOfflineEntries()
        }

        for entry in eligibleEntries {
            guard let account = matchingAccount(for: entry),
                let index = offlineEntries.firstIndex(where: {
                    $0.id == entry.id
                })
            else {
                continue
            }

            do {
                let remoteUserData = try await client.loadUserData(
                    accountID: account.id,
                    itemID: entry.remoteItemID
                )
                var mutableEntry = offlineEntries[index]
                let localChanged = !areUserDataEquivalent(
                    mutableEntry.localUserData,
                    mutableEntry.baselineUserData
                )
                let remoteChanged = !areUserDataEquivalent(
                    remoteUserData,
                    mutableEntry.baselineUserData
                )

                if !localChanged && !remoteChanged {
                    mutableEntry.localUserData = remoteUserData
                    mutableEntry.baselineUserData = remoteUserData
                    mutableEntry.syncState = .synced
                    mutableEntry.conflictingRemoteUserData = nil
                    mutableEntry.syncErrorMessage = nil
                    mutableEntry.lastSyncAt = Date()
                } else if !localChanged {
                    mutableEntry.localUserData = remoteUserData
                    mutableEntry.baselineUserData = remoteUserData
                    mutableEntry.syncState = .synced
                    mutableEntry.conflictingRemoteUserData = nil
                    mutableEntry.syncErrorMessage = nil
                    mutableEntry.lastSyncAt = Date()
                } else if !remoteChanged {
                    try await uploadOfflineUserData(
                        mutableEntry.localUserData,
                        for: mutableEntry,
                        accountID: account.id
                    )
                    mutableEntry.baselineUserData = mutableEntry.localUserData
                    mutableEntry.syncState = .synced
                    mutableEntry.conflictingRemoteUserData = nil
                    mutableEntry.syncErrorMessage = nil
                    mutableEntry.lastSyncAt = Date()
                } else {
                    switch autoResolveOfflineConflict(
                        local: mutableEntry.localUserData,
                        remote: remoteUserData
                    ) {
                    case .local:
                        try await uploadOfflineUserData(
                            mutableEntry.localUserData,
                            for: mutableEntry,
                            accountID: account.id
                        )
                        mutableEntry.baselineUserData =
                            mutableEntry.localUserData
                        mutableEntry.syncState = .synced
                        mutableEntry.conflictingRemoteUserData = nil
                        mutableEntry.syncErrorMessage = nil
                        mutableEntry.lastSyncAt = Date()
                    case .remote:
                        mutableEntry.localUserData = remoteUserData
                        mutableEntry.baselineUserData = remoteUserData
                        mutableEntry.syncState = .synced
                        mutableEntry.conflictingRemoteUserData = nil
                        mutableEntry.syncErrorMessage = nil
                        mutableEntry.lastSyncAt = Date()
                    case .conflict:
                        mutableEntry.syncState = .conflict
                        mutableEntry.conflictingRemoteUserData = remoteUserData
                        mutableEntry.syncErrorMessage = nil
                    }
                }

                offlineEntries[index] = mutableEntry
            } catch {
                var failedEntry = offlineEntries[index]
                failedEntry.syncState = .failed
                failedEntry.syncErrorMessage = error.localizedDescription
                offlineEntries[index] = failedEntry
            }
        }
    }

    func resolveOfflineConflict(entryID: UUID, preferLocal: Bool) async throws {
        guard let index = offlineEntries.firstIndex(where: { $0.id == entryID })
        else {
            return
        }
        var entry = offlineEntries[index]

        if preferLocal {
            if let account = matchingAccount(for: entry) {
                try await uploadOfflineUserData(
                    entry.localUserData,
                    for: entry,
                    accountID: account.id
                )
                entry.baselineUserData = entry.localUserData
                entry.syncState = .synced
                entry.lastSyncAt = Date()
            } else {
                entry.syncState = .pendingUpload
            }
        } else if let remoteUserData = entry.conflictingRemoteUserData {
            entry.localUserData = remoteUserData
            entry.baselineUserData = remoteUserData
            entry.syncState = .synced
            entry.lastSyncAt = Date()
        } else {
            entry.syncState = .pendingUpload
        }

        entry.conflictingRemoteUserData = nil
        entry.syncErrorMessage = nil
        offlineEntries[index] = entry
        saveOfflineEntries()
    }
}

extension JellyfinStore {
    fileprivate enum OfflineConflictResolution {
        case local
        case remote
        case conflict
    }

    fileprivate static func makeDefaultOfflineRootURL(fileManager: FileManager)
        -> URL
    {
        let baseURL =
            (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
        return
            baseURL
            .appendingPathComponent("Starmine", isDirectory: true)
            .appendingPathComponent("JellyfinOffline", isDirectory: true)
    }

    fileprivate func queueDownload(
        for selectedEpisodes: [JellyfinEpisode],
        in series: JellyfinMediaItem,
        season: JellyfinSeason?,
        account: JellyfinAccountProfile
    ) async throws {
        for episode in selectedEpisodes {
            enqueueOfflineDownloadJob(
                JellyfinOfflineDownloadJob(
                    taskID: UUID(),
                    accountID: account.id,
                    serverID: account.serverID,
                    userID: account.userID,
                    accountDisplayTitle: account.displayTitle,
                    libraryName: selectedLibrary?.name,
                    kind: .episode(
                        episode: episode,
                        series: series,
                        season: season
                    )
                ),
                remoteItemID: episode.id,
                title: episode.seriesName ?? series.name,
                detailTitle: episode.displayTitle,
                itemKind: .episode
            )
        }
    }

    fileprivate func queueDownloadForSeries(
        _ series: JellyfinMediaItem,
        account: JellyfinAccountProfile
    ) async throws {
        let allSeasons = try await client.loadSeasons(
            accountID: account.id,
            seriesID: series.id
        )
        for season in allSeasons {
            let seasonEpisodes = try await client.loadEpisodes(
                accountID: account.id,
                seriesID: series.id,
                seasonID: season.id
            )
            try await queueDownload(
                for: seasonEpisodes,
                in: series,
                season: season,
                account: account
            )
        }
    }

    fileprivate func enqueueOfflineDownloadJob(
        _ job: JellyfinOfflineDownloadJob,
        remoteItemID: String,
        title: String,
        detailTitle: String,
        itemKind: JellyfinItemKind
    ) {
        guard
            !offlineEntries.contains(where: {
                $0.remoteItemID == remoteItemID
                    && $0.serverID == job.serverID
                    && $0.userID == job.userID
            }),
            !hasPendingOrActiveOfflineDownload(
                remoteItemID: remoteItemID,
                serverID: job.serverID,
                userID: job.userID
            )
        else {
            return
        }

        pendingOfflineDownloadJobs.append(job)
        offlineDownloadTasks.append(
            JellyfinOfflineDownloadTask(
                id: job.taskID,
                remoteItemID: remoteItemID,
                title: title,
                detailTitle: detailTitle,
                itemKind: itemKind
            )
        )
        processOfflineDownloadQueueIfNeeded()
    }

    fileprivate func processOfflineDownloadQueueIfNeeded() {
        guard !isProcessingOfflineDownloadQueue else { return }
        isProcessingOfflineDownloadQueue = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pendingOfflineDownloadJobs.isEmpty {
                let job = self.pendingOfflineDownloadJobs.removeFirst()
                self.activeOfflineDownloadJob = job
                defer {
                    if self.activeOfflineDownloadJob?.taskID == job.taskID {
                        self.activeOfflineDownloadJob = nil
                    }
                }
                do {
                    try await self.performOfflineDownload(job)
                    self.offlineDownloadTasks.removeAll(where: {
                        $0.id == job.taskID
                    })
                } catch {
                    self.updateOfflineDownloadTask(
                        id: job.taskID,
                        phase: .failed,
                        progress: 1,
                        errorMessage: error.localizedDescription
                    )
                }
            }
            self.isProcessingOfflineDownloadQueue = false
        }
    }

    private func hasPendingOrActiveOfflineDownload(
        remoteItemID: String,
        serverID: String,
        userID: String
    ) -> Bool {
        pendingOfflineDownloadJobs.contains(where: {
            offlineDownloadJob(
                $0,
                matchesRemoteItemID: remoteItemID,
                serverID: serverID,
                userID: userID
            )
        })
            || activeOfflineDownloadJob.map {
                offlineDownloadJob(
                    $0,
                    matchesRemoteItemID: remoteItemID,
                    serverID: serverID,
                    userID: userID
                )
            } ?? false
    }

    private func offlineDownloadJob(
        _ job: JellyfinOfflineDownloadJob,
        matchesRemoteItemID remoteItemID: String,
        serverID: String,
        userID: String
    ) -> Bool {
        guard job.serverID == serverID, job.userID == userID else {
            return false
        }

        switch job.kind {
        case let .movie(item):
            return item.id == remoteItemID
        case let .episode(episode, _, _):
            return episode.id == remoteItemID
        }
    }

    fileprivate func performOfflineDownload(_ job: JellyfinOfflineDownloadJob)
        async throws
    {
        updateOfflineDownloadTask(
            id: job.taskID,
            phase: .resolving,
            progress: 0.12
        )

        switch job.kind {
        case let .movie(item):
            try await performMovieDownload(item, job: job)
        case let .episode(episode, series, season):
            try await performEpisodeDownload(
                episode,
                series: series,
                season: season,
                job: job
            )
        }
    }

    fileprivate func performMovieDownload(
        _ item: JellyfinMediaItem,
        job: JellyfinOfflineDownloadJob
    ) async throws {
        let session = try await client.createPlaybackSession(
            accountID: job.accountID,
            itemID: item.id,
            mediaSourceID: nil
        )
        let selectedSource =
            session.mediaSources.first(where: { $0.id == session.mediaSourceID }
            )
            ?? session.mediaSources.first
        let entryID = UUID()
        let entryDirectory = entryDirectoryURL(for: entryID)
        try recreateDirectory(entryDirectory)

        updateOfflineDownloadTask(
            id: job.taskID,
            phase: .downloadingVideo,
            progress: 0.48
        )
        let videoRelativePath = try await downloadVideo(
            from: session.streamURL,
            source: selectedSource,
            to: entryDirectory
        )

        updateOfflineDownloadTask(
            id: job.taskID,
            phase: .downloadingSubtitles,
            progress: 0.84
        )
        let subtitles = try await downloadSubtitles(
            from: selectedSource?.subtitleStreams ?? [],
            to: entryDirectory
        )

        updateOfflineDownloadTask(
            id: job.taskID,
            phase: .downloadingArtwork,
            progress: 0.94
        )
        let posterRelativePath = try await downloadArtwork(
            from: imageURL(
                accountID: job.accountID,
                itemID: item.id,
                imageType: "Primary",
                tag: item.imagePrimaryTag,
                width: 600,
                height: 900
            ),
            fallbackName: "poster",
            to: entryDirectory
        )
        let backdropRelativePath = try await downloadArtwork(
            from: imageURL(
                accountID: job.accountID,
                itemID: item.id,
                imageType: "Backdrop",
                tag: item.imageBackdropTag,
                width: 1600,
                height: 900,
                index: 0
            ),
            fallbackName: "backdrop",
            to: entryDirectory
        )
        let danmakuRelativePath = await cacheDanmakuPayload(
            query: item.name,
            remoteEpisodeID: item.id,
            to: entryDirectory
        )

        updateOfflineDownloadTask(
            id: job.taskID,
            phase: .finalizing,
            progress: 0.99
        )

        let entry = JellyfinOfflineEntry(
            id: entryID,
            serverID: job.serverID,
            userID: job.userID,
            accountDisplayTitle: job.accountDisplayTitle,
            sourceLibraryName: job.libraryName,
            remoteItemID: item.id,
            remoteItemKind: item.kind,
            title: item.name,
            episodeLabel: "",
            collectionTitle: nil,
            overview: item.overview,
            seriesID: nil,
            seriesTitle: nil,
            seasonID: nil,
            seasonTitle: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            productionYear: item.productionYear,
            communityRating: item.communityRating,
            runTimeTicks: item.runTimeTicks,
            videoRelativePath: relativeOfflinePath(
                for: entryID,
                localURL: entryDirectory.appendingPathComponent(
                    videoRelativePath
                )
            ),
            posterRelativePath: posterRelativePath.map {
                relativeOfflinePath(
                    for: entryID,
                    localURL: entryDirectory.appendingPathComponent($0)
                )
            },
            backdropRelativePath: backdropRelativePath.map {
                relativeOfflinePath(
                    for: entryID,
                    localURL: entryDirectory.appendingPathComponent($0)
                )
            },
            thumbnailRelativePath: nil,
            seasonPosterRelativePath: nil,
            danmakuRelativePath: danmakuRelativePath.map {
                relativeOfflinePath(
                    for: entryID,
                    localURL: entryDirectory.appendingPathComponent($0)
                )
            },
            subtitles: subtitles.map { subtitle in
                JellyfinOfflineSubtitle(
                    title: subtitle.title,
                    languageCode: subtitle.languageCode,
                    relativePath: relativeOfflinePath(
                        for: entryID,
                        localURL: entryDirectory.appendingPathComponent(
                            subtitle.relativePath
                        )
                    ),
                    isDefault: subtitle.isDefault,
                    isForced: subtitle.isForced
                )
            },
            localUserData: item.userData ?? JellyfinUserData(),
            baselineUserData: item.userData ?? JellyfinUserData(),
            lastSyncAt: Date(),
            byteCount: fileSize(
                at: entryDirectory.appendingPathComponent(videoRelativePath)
            )
        )
        offlineEntries.insert(entry, at: 0)
        saveOfflineEntries()
    }

    fileprivate func performEpisodeDownload(
        _ episode: JellyfinEpisode,
        series: JellyfinMediaItem?,
        season: JellyfinSeason?,
        job: JellyfinOfflineDownloadJob
    ) async throws {
        let session = try await client.createPlaybackSession(
            accountID: job.accountID,
            itemID: episode.id,
            mediaSourceID: nil
        )
        let selectedSource =
            session.mediaSources.first(where: { $0.id == session.mediaSourceID }
            )
            ?? session.mediaSources.first
        let entryID = UUID()
        let entryDirectory = entryDirectoryURL(for: entryID)
        try recreateDirectory(entryDirectory)

        updateOfflineDownloadTask(
            id: job.taskID,
            phase: .downloadingVideo,
            progress: 0.48
        )
        let videoRelativePath = try await downloadVideo(
            from: session.streamURL,
            source: selectedSource,
            to: entryDirectory
        )

        updateOfflineDownloadTask(
            id: job.taskID,
            phase: .downloadingSubtitles,
            progress: 0.84
        )
        let subtitles = try await downloadSubtitles(
            from: selectedSource?.subtitleStreams ?? [],
            to: entryDirectory
        )

        updateOfflineDownloadTask(
            id: job.taskID,
            phase: .downloadingArtwork,
            progress: 0.94
        )
        let thumbnailRelativePath = try await downloadArtwork(
            from: imageURL(
                accountID: job.accountID,
                itemID: episode.id,
                imageType: "Primary",
                tag: episode.imagePrimaryTag,
                width: 960,
                height: 540
            ),
            fallbackName: "thumbnail",
            to: entryDirectory
        )
        let posterRelativePath = try await downloadArtwork(
            from: series.flatMap {
                imageURL(
                    accountID: job.accountID,
                    itemID: $0.id,
                    imageType: "Primary",
                    tag: $0.imagePrimaryTag,
                    width: 600,
                    height: 900
                )
            },
            fallbackName: "poster",
            to: entryDirectory
        )
        let backdropRelativePath = try await downloadArtwork(
            from: series.flatMap {
                imageURL(
                    accountID: job.accountID,
                    itemID: $0.id,
                    imageType: "Backdrop",
                    tag: $0.imageBackdropTag,
                    width: 1600,
                    height: 900,
                    index: 0
                )
            },
            fallbackName: "backdrop",
            to: entryDirectory
        )
        let seasonPosterRelativePath = try await downloadArtwork(
            from: season.flatMap {
                imageURL(
                    accountID: job.accountID,
                    itemID: $0.id,
                    imageType: "Primary",
                    tag: $0.imagePrimaryTag,
                    width: 600,
                    height: 900
                )
            },
            fallbackName: "season-poster",
            to: entryDirectory
        )
        let danmakuRelativePath = await cacheDanmakuPayload(
            query: episode.seriesName ?? episode.name,
            inferredSeasonNumber: episode.parentIndexNumber
                ?? season?.indexNumber,
            inferredEpisodeNumber: episode.danmakuEpisodeOrdinal,
            remoteSeriesID: episode.seriesID ?? series?.id,
            remoteSeasonID: episode.seasonID ?? season?.id,
            remoteEpisodeID: episode.id,
            to: entryDirectory
        )

        updateOfflineDownloadTask(
            id: job.taskID,
            phase: .finalizing,
            progress: 0.99
        )

        let entry = JellyfinOfflineEntry(
            id: entryID,
            serverID: job.serverID,
            userID: job.userID,
            accountDisplayTitle: job.accountDisplayTitle,
            sourceLibraryName: job.libraryName,
            remoteItemID: episode.id,
            remoteItemKind: .episode,
            title: episode.name,
            episodeLabel: episode.displayTitle,
            collectionTitle: series?.name ?? episode.seriesName,
            overview: episode.overview,
            seriesID: episode.seriesID ?? series?.id,
            seriesTitle: episode.seriesName ?? series?.name,
            seasonID: episode.seasonID ?? season?.id,
            seasonTitle: episode.seasonName ?? season?.name,
            seasonNumber: episode.parentIndexNumber ?? season?.indexNumber,
            episodeNumber: episode.indexNumber,
            productionYear: nil,
            communityRating: nil,
            runTimeTicks: episode.runTimeTicks,
            videoRelativePath: relativeOfflinePath(
                for: entryID,
                localURL: entryDirectory.appendingPathComponent(
                    videoRelativePath
                )
            ),
            posterRelativePath: posterRelativePath.map {
                relativeOfflinePath(
                    for: entryID,
                    localURL: entryDirectory.appendingPathComponent($0)
                )
            },
            backdropRelativePath: backdropRelativePath.map {
                relativeOfflinePath(
                    for: entryID,
                    localURL: entryDirectory.appendingPathComponent($0)
                )
            },
            thumbnailRelativePath: thumbnailRelativePath.map {
                relativeOfflinePath(
                    for: entryID,
                    localURL: entryDirectory.appendingPathComponent($0)
                )
            },
            seasonPosterRelativePath: seasonPosterRelativePath.map {
                relativeOfflinePath(
                    for: entryID,
                    localURL: entryDirectory.appendingPathComponent($0)
                )
            },
            danmakuRelativePath: danmakuRelativePath.map {
                relativeOfflinePath(
                    for: entryID,
                    localURL: entryDirectory.appendingPathComponent($0)
                )
            },
            subtitles: subtitles.map { subtitle in
                JellyfinOfflineSubtitle(
                    title: subtitle.title,
                    languageCode: subtitle.languageCode,
                    relativePath: relativeOfflinePath(
                        for: entryID,
                        localURL: entryDirectory.appendingPathComponent(
                            subtitle.relativePath
                        )
                    ),
                    isDefault: subtitle.isDefault,
                    isForced: subtitle.isForced
                )
            },
            localUserData: episode.userData ?? JellyfinUserData(),
            baselineUserData: episode.userData ?? JellyfinUserData(),
            lastSyncAt: Date(),
            byteCount: fileSize(
                at: entryDirectory.appendingPathComponent(videoRelativePath)
            )
        )
        offlineEntries.insert(entry, at: 0)
        saveOfflineEntries()
    }

    fileprivate func updateOfflineDownloadTask(
        id: UUID,
        phase: JellyfinOfflineDownloadPhase,
        progress: Double,
        errorMessage: String? = nil
    ) {
        guard
            let index = offlineDownloadTasks.firstIndex(where: { $0.id == id })
        else {
            return
        }
        offlineDownloadTasks[index].phase = phase
        offlineDownloadTasks[index].progress = progress
        offlineDownloadTasks[index].errorMessage = errorMessage
    }

    fileprivate func loadOfflineEntries() {
        ensureOfflineDirectories()
        let manifestURL = offlineManifestURL()
        guard
            let data = try? Data(contentsOf: manifestURL),
            let decoded = try? makeOfflineDecoder().decode(
                [JellyfinOfflineEntry].self,
                from: data
            )
        else {
            offlineEntries = []
            return
        }
        offlineEntries = decoded.filter { entry in
            resolvedOfflineFileURL(relativePath: entry.videoRelativePath) != nil
        }
    }

    fileprivate func saveOfflineEntries() {
        ensureOfflineDirectories()
        let encoder = makeOfflineEncoder()
        guard let data = try? encoder.encode(offlineEntries) else { return }
        try? data.write(to: offlineManifestURL(), options: .atomic)
    }

    fileprivate func matchingAccount(for entry: JellyfinOfflineEntry)
        -> JellyfinAccountProfile?
    {
        accounts.first(where: {
            $0.serverID == entry.serverID && $0.userID == entry.userID
        })
    }

    fileprivate func ensureOfflineDirectories() {
        try? fileManager.createDirectory(
            at: offlineEntriesDirectoryURL(),
            withIntermediateDirectories: true
        )
    }

    fileprivate func offlineEntriesDirectoryURL() -> URL {
        offlineRootURL.appendingPathComponent("Entries", isDirectory: true)
    }

    fileprivate func offlineManifestURL() -> URL {
        offlineRootURL.appendingPathComponent("manifest.json")
    }

    fileprivate func entryDirectoryURL(for entryID: UUID) -> URL {
        offlineEntriesDirectoryURL()
            .appendingPathComponent(entryID.uuidString, isDirectory: true)
    }

    fileprivate func resolvedOfflineFileURL(relativePath: String?) -> URL? {
        guard let relativePath = relativePath?.nilIfBlank else { return nil }
        let url = offlineRootURL.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    fileprivate func relativeOfflinePath(for entryID: UUID, localURL: URL)
        -> String
    {
        "Entries/\(entryID.uuidString)/\(localURL.lastPathComponent)"
    }

    fileprivate func makeOfflineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    fileprivate func makeOfflineDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    fileprivate func recreateDirectory(_ directoryURL: URL) throws {
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    fileprivate func downloadVideo(
        from url: URL,
        source: JellyfinPlaybackMediaSource?,
        to directoryURL: URL
    ) async throws -> String {
        let (temporaryURL, response) = try await URLSession.shared.download(
            from: url
        )
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw JellyfinClientError.requestFailed("视频下载失败。")
        }

        let suggestedExtension = response.suggestedFilename.flatMap {
            URL(fileURLWithPath: $0).pathExtension.nilIfBlank
        }
        let sourceContainerExtension = source?.container?
            .split(separator: ",")
            .first
            .map(String.init)?
            .nilIfBlank
        let urlExtension = url.pathExtension.nilIfBlank
        let fileExtension =
            suggestedExtension
            ?? sourceContainerExtension
            ?? urlExtension
            ?? "mp4"
        let filename = "video.\(fileExtension)"
        let destinationURL = directoryURL.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return filename
    }

    fileprivate func downloadSubtitles(
        from streams: [JellyfinPlaybackSubtitleStream],
        to directoryURL: URL
    ) async throws -> [(
        title: String,
        languageCode: String?,
        relativePath: String,
        isDefault: Bool,
        isForced: Bool
    )] {
        let externalStreams = streams.filter {
            $0.isExternal && $0.streamURL != nil
        }
        var results:
            [(
                title: String,
                languageCode: String?,
                relativePath: String,
                isDefault: Bool,
                isForced: Bool
            )] = []

        for stream in externalStreams {
            guard let streamURL = stream.streamURL else { continue }
            let (data, response) = try await URLSession.shared.data(
                from: streamURL
            )
            guard let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                continue
            }

            let sanitizedName = sanitizedFilenameComponent(
                stream.languageCode ?? stream.title ?? "subtitle"
            )
            let filename =
                "subtitle-\(stream.index)-\(sanitizedName).\(stream.fileExtension)"
            let destinationURL = directoryURL.appendingPathComponent(filename)
            try data.write(to: destinationURL, options: .atomic)
            results.append(
                (
                    title: stream.displayTitle,
                    languageCode: stream.languageCode,
                    relativePath: filename,
                    isDefault: stream.isDefault,
                    isForced: stream.isForced
                )
            )
        }

        return results
    }

    fileprivate func downloadArtwork(
        from url: URL?,
        fallbackName: String,
        to directoryURL: URL
    ) async throws -> String? {
        guard let url else { return nil }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            return nil
        }
        let fileExtension =
            url.pathExtension.nilIfBlank
            ?? response.suggestedFilename.flatMap {
                URL(fileURLWithPath: $0).pathExtension.nilIfBlank
            }
            ?? "jpg"
        let filename = "\(fallbackName).\(fileExtension)"
        let destinationURL = directoryURL.appendingPathComponent(filename)
        try data.write(to: destinationURL, options: .atomic)
        return filename
    }

    func cacheDanmakuPayload(
        query: String,
        inferredSeasonNumber: Int? = nil,
        inferredSeasonEpisodeCount: Int? = nil,
        inferredEpisodeNumber: Int? = nil,
        remoteSeriesID: String? = nil,
        remoteSeasonID: String? = nil,
        remoteEpisodeID: String? = nil,
        to directoryURL: URL
    ) async -> String? {
        let trimmedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedQuery.isEmpty else { return nil }

        danmakuPrefetchStore.prepareSearch(
            query: trimmedQuery,
            inferredSeasonNumber: inferredSeasonNumber,
            inferredSeasonEpisodeCount: inferredSeasonEpisodeCount,
            inferredEpisodeNumber: inferredEpisodeNumber,
            remoteSeriesID: remoteSeriesID,
            remoteSeasonID: remoteSeasonID,
            remoteEpisodeID: remoteEpisodeID
        )

        defer { danmakuPrefetchStore.clearAll() }

        do {
            guard
                let matchedEpisode =
                    try await danmakuPrefetchStore.searchAndAutoloadDanmaku(
                        persistRemoteMapping: false
                    ),
                let matchedAnime = danmakuPrefetchStore.selectedAnime
            else {
                return nil
            }

            let payload = DanmakuOfflineCachePayload(
                anime: matchedAnime,
                episode: matchedEpisode,
                comments: danmakuPrefetchStore.renderer.loadedComments
            )
            let filename = "danmaku.json"
            let destinationURL = directoryURL.appendingPathComponent(filename)
            try JSONEncoder().encode(payload).write(
                to: destinationURL,
                options: .atomic
            )
            return filename
        } catch {
            return nil
        }
    }

    fileprivate func fileSize(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    fileprivate func sanitizedFilenameComponent(_ rawValue: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned =
            rawValue
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.nilIfBlank ?? "item"
    }

    fileprivate func clearOfflineNavigation() {
        previousOfflineEntry = nil
        nextOfflineEntry = nil
    }

    fileprivate func refreshOfflineNavigationForActivePlaybackIfNeeded() {
        guard let activeEntryID = activeTrackedOfflinePlayback?.entryID else {
            return
        }
        guard
            let activeEntry = offlineEntries.first(where: {
                $0.id == activeEntryID
            })
        else {
            clearOfflineNavigation()
            return
        }
        resolveOfflineNavigation(for: activeEntry)
    }

    fileprivate func resolveOfflineNavigation(for entry: JellyfinOfflineEntry) {
        guard entry.remoteItemKind == .episode else {
            clearOfflineNavigation()
            return
        }

        let siblings =
            offlineEntries
            .filter {
                $0.remoteItemKind == .episode
                    && $0.serverID == entry.serverID
                    && $0.userID == entry.userID
                    && $0.seriesID == entry.seriesID
            }
            .sorted { lhs, rhs in
                if lhs.seasonNumber != rhs.seasonNumber {
                    return (lhs.seasonNumber ?? 0) < (rhs.seasonNumber ?? 0)
                }
                if lhs.episodeNumber != rhs.episodeNumber {
                    return (lhs.episodeNumber ?? 0) < (rhs.episodeNumber ?? 0)
                }
                return lhs.detailTitle.localizedCaseInsensitiveCompare(
                    rhs.detailTitle
                ) == .orderedAscending
            }

        guard let index = siblings.firstIndex(where: { $0.id == entry.id })
        else {
            clearOfflineNavigation()
            return
        }

        previousOfflineEntry = index > 0 ? siblings[index - 1] : nil
        nextOfflineEntry =
            siblings.indices.contains(index + 1)
            ? siblings[index + 1] : nil
    }

    fileprivate func applyOfflinePlaybackProgressLocally(
        entryID: UUID,
        positionSeconds: Double,
        finished: Bool,
        playedAt: Date = Date()
    ) {
        guard let index = offlineEntries.firstIndex(where: { $0.id == entryID })
        else {
            return
        }
        var entry = offlineEntries[index]
        entry.localUserData = updatedUserData(
            from: entry.localUserData,
            positionSeconds: positionSeconds,
            finished: finished,
            playedAt: playedAt
        )
        markOfflineEntryForLocalChange(&entry, playedAt: playedAt)
        offlineEntries[index] = entry
        saveOfflineEntries()
    }

    fileprivate func markOfflineEntryForLocalChange(
        _ entry: inout JellyfinOfflineEntry,
        playedAt: Date
    ) {
        entry.lastLocalUpdateAt = playedAt
        entry.syncErrorMessage = nil
        entry.conflictingRemoteUserData = nil
        entry.syncState =
            areUserDataEquivalent(entry.localUserData, entry.baselineUserData)
            ? .synced : .pendingUpload
    }

    fileprivate func uploadOfflineUserData(
        _ userData: JellyfinUserData,
        for entry: JellyfinOfflineEntry,
        accountID: UUID
    ) async throws {
        if userData.played == true {
            try await client.markPlayed(
                accountID: accountID,
                itemID: entry.remoteItemID
            )
            return
        }

        let position = userData.playbackPositionSeconds ?? 0
        guard position > 1 else {
            try await client.markUnplayed(
                accountID: accountID,
                itemID: entry.remoteItemID
            )
            return
        }

        let session = try await client.createPlaybackSession(
            accountID: accountID,
            itemID: entry.remoteItemID,
            mediaSourceID: nil
        )
        try? await client.reportPlaybackStarted(
            accountID: accountID,
            session: session,
            positionSeconds: position,
            isPaused: true
        )
        try await client.reportPlaybackStopped(
            accountID: accountID,
            session: session,
            positionSeconds: position,
            isPaused: true,
            finished: false
        )
    }

    fileprivate func autoResolveOfflineConflict(
        local: JellyfinUserData,
        remote: JellyfinUserData
    ) -> OfflineConflictResolution {
        let localDate = local.lastPlayedDate ?? .distantPast
        let remoteDate = remote.lastPlayedDate ?? .distantPast
        let delta = localDate.timeIntervalSince(remoteDate)

        if abs(delta) >= 300 {
            return delta >= 0 ? .local : .remote
        }

        let localScore = offlineProgressPriority(local)
        let remoteScore = offlineProgressPriority(remote)
        if localScore != remoteScore {
            return localScore > remoteScore ? .local : .remote
        }

        let localPosition = local.playbackPositionSeconds ?? 0
        let remotePosition = remote.playbackPositionSeconds ?? 0
        if abs(localPosition - remotePosition) >= 120 {
            return localPosition > remotePosition ? .local : .remote
        }

        return .conflict
    }

    fileprivate func offlineProgressPriority(_ userData: JellyfinUserData)
        -> Int
    {
        if userData.played == true {
            return 2
        }
        if (userData.playbackPositionSeconds ?? 0) > 15 {
            return 1
        }
        return 0
    }

    fileprivate func areUserDataEquivalent(
        _ lhs: JellyfinUserData,
        _ rhs: JellyfinUserData
    ) -> Bool {
        if lhs.played != rhs.played {
            return false
        }
        let leftPosition = lhs.playbackPositionSeconds ?? 0
        let rightPosition = rhs.playbackPositionSeconds ?? 0
        return abs(leftPosition - rightPosition) < 15
    }
}
