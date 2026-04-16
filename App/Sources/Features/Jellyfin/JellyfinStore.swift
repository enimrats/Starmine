import Combine
import Foundation

struct JellyfinPlaybackCandidate: Hashable {
    var session: JellyfinPlaybackSession
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

@MainActor
final class JellyfinStore: ObservableObject {
    @Published var accounts: [JellyfinAccountProfile] = []
    @Published var selectedAccountID: UUID?
    @Published var libraries: [JellyfinLibrary] = []
    @Published var selectedLibraryID: String?
    @Published var items: [JellyfinMediaItem] = []
    @Published var selectedItemID: String?
    @Published var seasons: [JellyfinSeason] = []
    @Published var selectedSeasonID: String?
    @Published var episodes: [JellyfinEpisode] = []
    @Published var selectedEpisodeID: String?
    @Published var isLoading = false
    @Published var isConnecting = false

    private let client: any JellyfinClientProtocol
    private(set) var previousRemoteEpisode: JellyfinEpisode?
    private(set) var nextRemoteEpisode: JellyfinEpisode?

    init(client: any JellyfinClientProtocol = JellyfinClient.shared) {
        self.client = client
    }

    var activeAccount: JellyfinAccountProfile? {
        accounts.first(where: { $0.id == selectedAccountID })
    }

    var activeRoute: JellyfinRoute? {
        activeAccount?.activeRoute
    }

    var selectedLibrary: JellyfinLibrary? {
        libraries.first(where: { $0.id == selectedLibraryID })
    }

    var selectedItem: JellyfinMediaItem? {
        items.first(where: { $0.id == selectedItemID })
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
        guard selectedAccountID != nil else { return }
        try await refreshLibrary()
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

    func switchRoute(_ routeID: UUID) async throws {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }
        let snapshot = try await client.switchRoute(
            accountID: accountID,
            routeID: routeID
        )
        applySnapshot(snapshot)
    }

    func removeSelectedAccount() async throws {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }
        let snapshot = try await client.removeAccount(accountID)
        applySnapshot(snapshot)
        clearBrowseState(clearLibraries: selectedAccountID == nil)
        if selectedAccountID != nil {
            try await refreshLibrary()
        }
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

    func makePlaybackCandidate(for item: JellyfinMediaItem) async throws
        -> JellyfinPlaybackCandidate
    {
        guard let accountID = selectedAccountID else {
            throw JellyfinClientError.accountNotFound
        }

        let session = try await client.createPlaybackSession(
            accountID: accountID,
            itemID: item.id,
            mediaSourceID: nil
        )
        let snapshot = await client.snapshot()
        applySnapshot(snapshot)
        selectedEpisodeID = nil
        clearRemoteNavigation()

        return JellyfinPlaybackCandidate(
            session: session,
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

        let session = try await client.createPlaybackSession(
            accountID: accountID,
            itemID: episode.id,
            mediaSourceID: nil
        )
        let snapshot = await client.snapshot()
        applySnapshot(snapshot)
        selectedItemID = episode.seriesID ?? selectedItemID
        selectedEpisodeID = episode.id

        await resolveRemoteEpisodeNeighbors(for: episode)

        let seasonEpisodeCount = episodes.filter {
            $0.danmakuEpisodeOrdinal != nil
        }.count

        return JellyfinPlaybackCandidate(
            session: session,
            title: episode.seriesName ?? episode.name,
            episodeLabel: episode.displayTitle,
            collectionTitle: episode.seriesName,
            danmakuQuery: episode.seriesName ?? episode.name,
            remoteSeriesID: episode.seriesID ?? selectedItemID,
            remoteSeasonID: episode.seasonID,
            remoteEpisodeID: episode.id,
            seasonNumber: episode.parentIndexNumber,
            seasonEpisodeCount: seasonEpisodeCount > 0
                ? seasonEpisodeCount : nil,
            episodeNumber: episode.danmakuEpisodeOrdinal,
            resumePosition: episode.resumePositionSeconds
        )
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
    }

    private func clearSelectionState() {
        selectedItemID = nil
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

    private func imageURL(
        itemID: String,
        imageType: String,
        tag: String?,
        width: Int?,
        height: Int?,
        index: Int? = nil,
        quality: Int = 90
    ) -> URL? {
        guard let account = activeAccount, let route = activeRoute else {
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

    private func resolveRemoteEpisodeNeighbors(for episode: JellyfinEpisode)
        async
    {
        previousRemoteEpisode = nil
        nextRemoteEpisode = nil

        if let index = episodes.firstIndex(where: { $0.id == episode.id }) {
            if index > 0 {
                previousRemoteEpisode = episodes[index - 1]
            }
            if episodes.indices.contains(index + 1) {
                nextRemoteEpisode = episodes[index + 1]
            }
        }

        if previousRemoteEpisode != nil && nextRemoteEpisode != nil {
            return
        }

        guard let accountID = selectedAccountID else {
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
}
