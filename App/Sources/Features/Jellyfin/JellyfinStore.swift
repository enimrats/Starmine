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

    private let client: any JellyfinClientProtocol
    private let defaults: UserDefaults
    private(set) var previousRemoteEpisode: JellyfinEpisode?
    private(set) var nextRemoteEpisode: JellyfinEpisode?
    private var activeTrackedPlayback: JellyfinTrackedPlayback?
    private var selectedItemOverride: JellyfinMediaItem?

    init(
        client: any JellyfinClientProtocol = JellyfinClient.shared,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.defaults = defaults
    }

    var activeAccount: JellyfinAccountProfile? {
        accounts.first(where: { $0.id == selectedAccountID })
    }

    var activeRoute: JellyfinRoute? {
        activeAccount?.activeRoute
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
        previousRemoteEpisode != nil
    }

    var canPlayNextEpisode: Bool {
        nextRemoteEpisode != nil
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
        try await refreshHome()
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
    }

    func refreshHome() async throws {
        guard let accountID = homeAccountID else {
            clearHomeState()
            return
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

    func refreshLibrary() async throws {
        guard let accountID = selectedAccountID else {
            clearBrowseState(clearLibraries: true)
            return
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

    private func applySnapshot(_ snapshot: JellyfinStoreSnapshot) {
        accounts = snapshot.accounts
        if let activeID = snapshot.activeAccountID,
            snapshot.accounts.contains(where: { $0.id == activeID })
        {
            selectedAccountID = activeID
        } else {
            selectedAccountID = snapshot.accounts.first?.id
        }

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
        updated.playbackPositionTicks =
            played ? 0 : updated.playbackPositionTicks
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
