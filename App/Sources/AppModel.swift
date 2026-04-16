import Foundation
import MediaPlayer
import SwiftUI
#if os(iOS)
import AVFoundation
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var searchQuery = ""
    @Published var searchResults: [AnimeSearchResult] = []
    @Published var selectedAnimeID: AnimeSearchResult.ID?
    @Published var episodes: [AnimeEpisode] = []
    @Published var selectedEpisodeID: AnimeEpisode.ID?
    @Published var playback = PlaybackSnapshot()
    @Published var currentVideoURL: URL?
    @Published var currentVideoTitle = "Starmine"
    @Published var currentEpisodeLabel = ""
    @Published var danmakuEnabled = true
    @Published var isSearching = false
    @Published var isLoadingDanmaku = false
    @Published var audioTracks: [MediaTrackOption] = []
    @Published var subtitleTracks: [MediaTrackOption] = []
    @Published var selectedAudioTrackID: Int64?
    @Published var selectedSubtitleTrackID: Int64?
    @Published var jellyfinAccounts: [JellyfinAccountProfile] = []
    @Published var selectedJellyfinAccountID: UUID?
    @Published var jellyfinLibraries: [JellyfinLibrary] = []
    @Published var selectedJellyfinLibraryID: String?
    @Published var jellyfinItems: [JellyfinMediaItem] = []
    @Published var selectedJellyfinItemID: String?
    @Published var jellyfinSeasons: [JellyfinSeason] = []
    @Published var selectedJellyfinSeasonID: String?
    @Published var jellyfinEpisodes: [JellyfinEpisode] = []
    @Published var selectedJellyfinEpisodeID: String?
    @Published var isLoadingJellyfin = false
    @Published var isConnectingJellyfin = false
    @Published var isPlayingRemote = false
    @Published var errorState: AppErrorState?
    
    let player = MPVPlayerController()
    let danmakuStore = DanmakuOverlayStore()
    
    private let dandanplayClient = DandanplayClient()
    private let jellyfinClient = JellyfinClient.shared
    private let systemMediaController = SystemMediaController()
    private var currentScopedURL: URL?
    private var inferredEpisodeNumber: Int?
    private var remotePlaybackContext: RemotePlaybackContext?
    private var previousRemoteEpisode: JellyfinEpisode?
    private var nextRemoteEpisode: JellyfinEpisode?
    private var currentCollectionTitle: String?
    
    init() {
        player.onSnapshot = { [weak self] snapshot in
            self?.playback = snapshot
            self?.refreshSystemMediaState()
        }
        player.onLogMessage = { [weak self] message in
#if DEBUG
            print("[mpv] \(message)")
#endif
            if Self.shouldSurfacePlayerError(message) {
                self?.errorState = AppErrorState(message: message)
            }
        }
        player.onTrackState = { [weak self] trackState in
            self?.audioTracks = trackState.audioTracks
            self?.subtitleTracks = trackState.subtitleTracks
            self?.selectedAudioTrackID = trackState.selectedAudioID
            self?.selectedSubtitleTrackID = trackState.selectedSubtitleID
        }
        systemMediaController.onPlay = { [weak self] in
            self?.play()
        }
        systemMediaController.onPause = { [weak self] in
            self?.pause()
        }
        systemMediaController.onTogglePlayPause = { [weak self] in
            self?.togglePause()
        }
        systemMediaController.onSeek = { [weak self] position in
            self?.seek(to: position)
        }
        systemMediaController.onSkipForward = { [weak self] interval in
            self?.seek(relative: interval)
        }
        systemMediaController.onSkipBackward = { [weak self] interval in
            self?.seek(relative: -interval)
        }
        systemMediaController.onNextTrack = { [weak self] in
            self?.playNextEpisode()
        }
        systemMediaController.onPreviousTrack = { [weak self] in
            self?.playPreviousEpisode()
        }
        refreshSystemMediaState()
        
        Task { [weak self] in
            await self?.restoreJellyfinState()
        }
    }
    
    deinit {
        currentScopedURL?.stopAccessingSecurityScopedResource()
    }
    
    var selectedAnime: AnimeSearchResult? {
        searchResults.first(where: { $0.id == selectedAnimeID })
    }
    
    var selectedEpisode: AnimeEpisode? {
        episodes.first(where: { $0.id == selectedEpisodeID })
    }
    
    var selectedAudioTrack: MediaTrackOption? {
        audioTracks.first(where: { $0.mpvID == selectedAudioTrackID })
    }
    
    var selectedSubtitleTrack: MediaTrackOption? {
        subtitleTracks.first(where: { $0.mpvID == selectedSubtitleTrackID })
    }
    
    var activeJellyfinAccount: JellyfinAccountProfile? {
        jellyfinAccounts.first(where: { $0.id == selectedJellyfinAccountID })
    }
    
    var activeJellyfinRoute: JellyfinRoute? {
        activeJellyfinAccount?.activeRoute
    }
    
    var selectedJellyfinLibrary: JellyfinLibrary? {
        jellyfinLibraries.first(where: { $0.id == selectedJellyfinLibraryID })
    }
    
    var selectedJellyfinItem: JellyfinMediaItem? {
        jellyfinItems.first(where: { $0.id == selectedJellyfinItemID })
    }
    
    var selectedJellyfinSeason: JellyfinSeason? {
        jellyfinSeasons.first(where: { $0.id == selectedJellyfinSeasonID })
    }
    
    var selectedJellyfinEpisode: JellyfinEpisode? {
        jellyfinEpisodes.first(where: { $0.id == selectedJellyfinEpisodeID })
    }
    
    var canPlayPreviousEpisode: Bool {
        previousRemoteEpisode != nil
    }
    
    var canPlayNextEpisode: Bool {
        nextRemoteEpisode != nil
    }
    
    func jellyfinLibraryImageURL(_ library: JellyfinLibrary, width: Int = 320, height: Int = 190) -> URL? {
        jellyfinImageURL(
            itemID: library.id,
            imageType: "Primary",
            tag: library.imageTag,
            width: width,
            height: height
        )
    }
    
    func jellyfinPosterURL(for item: JellyfinMediaItem, width: Int = 440, height: Int = 660) -> URL? {
        jellyfinImageURL(
            itemID: item.id,
            imageType: "Primary",
            tag: item.imagePrimaryTag,
            width: width,
            height: height
        )
    }
    
    func jellyfinBackdropURL(for item: JellyfinMediaItem, width: Int = 1400, height: Int = 700) -> URL? {
        jellyfinImageURL(
            itemID: item.id,
            imageType: "Backdrop",
            tag: item.imageBackdropTag,
            width: width,
            height: height,
            index: 0
        )
    }
    
    func jellyfinPosterURL(for season: JellyfinSeason, width: Int = 320, height: Int = 480) -> URL? {
        jellyfinImageURL(
            itemID: season.id,
            imageType: "Primary",
            tag: season.imagePrimaryTag,
            width: width,
            height: height
        )
    }
    
    func jellyfinEpisodeThumbnailURL(_ episode: JellyfinEpisode, width: Int = 480, height: Int = 270) -> URL? {
        jellyfinImageURL(
            itemID: episode.id,
            imageType: "Primary",
            tag: episode.imagePrimaryTag,
            width: width,
            height: height
        )
    }
    
    func openVideo(url: URL) {
        currentScopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() {
            currentScopedURL = url
        } else {
            currentScopedURL = nil
        }
        
        clearRemotePlaybackContext()
        currentVideoURL = url
        currentVideoTitle = url.lastPathComponent
        currentEpisodeLabel = ""
        searchResults = []
        selectedAnimeID = nil
        episodes = []
        danmakuStore.clear()
        selectedEpisodeID = nil
        resetTrackSelections()
        refreshSystemMediaState()
        player.load(url)
        
        let cleanedTitle = Self.cleanSearchKeyword(from: url.deletingPathExtension().lastPathComponent)
        searchQuery = cleanedTitle
        inferredEpisodeNumber = Self.extractEpisodeNumber(from: cleanedTitle)
        
        Task {
            await searchAndAutoloadDanmaku()
        }
    }
    
    func restoreJellyfinState() async {
        let snapshot = await jellyfinClient.snapshot()
        applyJellyfinSnapshot(snapshot)
        guard selectedJellyfinAccountID != nil else { return }
        await refreshJellyfinLibrary()
    }
    
    func connectJellyfin(serverURL: String, username: String, password: String, routeName: String?) async -> Bool {
        isConnectingJellyfin = true
        defer { isConnectingJellyfin = false }
        
        do {
            let snapshot = try await jellyfinClient.connect(
                serverURL: serverURL,
                username: username,
                password: password,
                routeName: routeName
            )
            applyJellyfinSnapshot(snapshot)
            clearJellyfinBrowseState(clearLibraries: true)
            await refreshJellyfinLibrary()
            return true
        } catch {
            errorState = AppErrorState(message: error.localizedDescription)
            return false
        }
    }
    
    func addJellyfinRoute(serverURL: String, routeName: String?) async -> Bool {
        guard let accountID = selectedJellyfinAccountID else { return false }
        
        isConnectingJellyfin = true
        defer { isConnectingJellyfin = false }
        
        do {
            let snapshot = try await jellyfinClient.addRoute(
                accountID: accountID,
                serverURL: serverURL,
                routeName: routeName
            )
            applyJellyfinSnapshot(snapshot)
            return true
        } catch {
            errorState = AppErrorState(message: error.localizedDescription)
            return false
        }
    }
    
    func switchJellyfinAccount(_ accountID: UUID) {
        Task {
            do {
                let snapshot = try await jellyfinClient.setActiveAccount(accountID)
                applyJellyfinSnapshot(snapshot)
                clearJellyfinBrowseState(clearLibraries: true)
                await refreshJellyfinLibrary()
            } catch {
                errorState = AppErrorState(message: error.localizedDescription)
            }
        }
    }
    
    func switchJellyfinRoute(_ routeID: UUID) {
        guard let accountID = selectedJellyfinAccountID else { return }
        Task {
            do {
                let snapshot = try await jellyfinClient.switchRoute(accountID: accountID, routeID: routeID)
                applyJellyfinSnapshot(snapshot)
                refreshSystemMediaState()
            } catch {
                errorState = AppErrorState(message: error.localizedDescription)
            }
        }
    }
    
    func removeSelectedJellyfinAccount() {
        guard let accountID = selectedJellyfinAccountID else { return }
        Task {
            do {
                let snapshot = try await jellyfinClient.removeAccount(accountID)
                applyJellyfinSnapshot(snapshot)
                clearJellyfinBrowseState(clearLibraries: selectedJellyfinAccountID == nil)
                if selectedJellyfinAccountID != nil {
                    await refreshJellyfinLibrary()
                }
            } catch {
                errorState = AppErrorState(message: error.localizedDescription)
            }
        }
    }
    
    func refreshJellyfinLibrary() async {
        guard let accountID = selectedJellyfinAccountID else {
            clearJellyfinBrowseState(clearLibraries: true)
            return
        }
        
        isLoadingJellyfin = true
        defer { isLoadingJellyfin = false }
        
        do {
            let libraries = try await jellyfinClient.loadLibraries(accountID: accountID)
            let snapshot = await jellyfinClient.snapshot()
            applyJellyfinSnapshot(snapshot)
            jellyfinLibraries = libraries
            
            let rememberedLibraryID = activeJellyfinAccount?.lastSelectedLibraryID
            let resolvedLibraryID = selectedJellyfinLibraryID.flatMap { currentID in
                libraries.contains(where: { $0.id == currentID }) ? currentID : nil
            } ?? rememberedLibraryID.flatMap { savedID in
                libraries.contains(where: { $0.id == savedID }) ? savedID : nil
            } ?? libraries.first?.id
            
            let updatedSnapshot = await jellyfinClient.rememberSelectedLibrary(accountID: accountID, libraryID: resolvedLibraryID)
            applyJellyfinSnapshot(updatedSnapshot)
            selectedJellyfinLibraryID = resolvedLibraryID
            
            if let resolvedLibraryID {
                try await loadJellyfinItems(for: resolvedLibraryID, accountID: accountID)
            } else {
                clearJellyfinBrowseState(clearLibraries: false)
            }
        } catch {
            errorState = AppErrorState(message: error.localizedDescription)
        }
    }
    
    func selectJellyfinLibrary(_ library: JellyfinLibrary) {
        guard let accountID = selectedJellyfinAccountID else { return }
        selectedJellyfinLibraryID = library.id
        clearJellyfinSelectionState()
        
        Task {
            let snapshot = await jellyfinClient.rememberSelectedLibrary(accountID: accountID, libraryID: library.id)
            applyJellyfinSnapshot(snapshot)
            do {
                try await loadJellyfinItems(for: library.id, accountID: accountID)
            } catch {
                errorState = AppErrorState(message: error.localizedDescription)
            }
        }
    }
    
    func selectJellyfinItem(_ item: JellyfinMediaItem) {
        selectedJellyfinItemID = item.id
        selectedJellyfinSeasonID = nil
        selectedJellyfinEpisodeID = nil
        jellyfinSeasons = []
        jellyfinEpisodes = []
        previousRemoteEpisode = nil
        nextRemoteEpisode = nil
        refreshSystemMediaState()
        
        Task {
            switch item.kind {
            case .series:
                await loadSeasons(for: item)
            default:
                break
            }
        }
    }
    
    func playJellyfinMediaItem(_ item: JellyfinMediaItem) {
        Task {
            await startJellyfinItemPlayback(item)
        }
    }
    
    func selectJellyfinSeason(_ season: JellyfinSeason) {
        guard let accountID = selectedJellyfinAccountID else { return }
        selectedJellyfinSeasonID = season.id
        selectedJellyfinEpisodeID = nil
        previousRemoteEpisode = nil
        nextRemoteEpisode = nil
        refreshSystemMediaState()
        
        Task {
            do {
                let seriesID = season.seriesID ?? selectedJellyfinItemID ?? ""
                guard !seriesID.isEmpty else { return }
                let loadedEpisodes = try await jellyfinClient.loadEpisodes(
                    accountID: accountID,
                    seriesID: seriesID,
                    seasonID: season.id
                )
                jellyfinEpisodes = loadedEpisodes
                let snapshot = await jellyfinClient.snapshot()
                applyJellyfinSnapshot(snapshot)
            } catch {
                errorState = AppErrorState(message: error.localizedDescription)
            }
        }
    }
    
    func playJellyfinEpisode(_ episode: JellyfinEpisode) {
        Task {
            await playRemoteEpisode(episode)
        }
    }
    
    func playPreviousEpisode() {
        guard let previousRemoteEpisode else { return }
        playJellyfinEpisode(previousRemoteEpisode)
    }
    
    func playNextEpisode() {
        guard let nextRemoteEpisode else { return }
        playJellyfinEpisode(nextRemoteEpisode)
    }
    
    func searchAndAutoloadDanmaku() async {
        let keyword = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            searchResults = []
            episodes = []
            selectedAnimeID = nil
            refreshSystemMediaState()
            return
        }
        
        isSearching = true
        defer { isSearching = false }
        
        do {
            let results = try await dandanplayClient.searchAnime(keyword: keyword)
            searchResults = results
            guard let bestMatch = results.first else {
                episodes = []
                selectedAnimeID = nil
                refreshSystemMediaState()
                return
            }
            selectedAnimeID = bestMatch.id
            refreshSystemMediaState()
            try await loadEpisodes(
                for: bestMatch,
                autoloadDanmaku: true,
                updatePlaybackLabel: remotePlaybackContext == nil
            )
        } catch {
            errorState = AppErrorState(message: error.localizedDescription)
        }
    }
    
    func pickAnime(_ anime: AnimeSearchResult) {
        selectedAnimeID = anime.id
        refreshSystemMediaState()
        Task {
            do {
                try await loadEpisodes(
                    for: anime,
                    autoloadDanmaku: true,
                    updatePlaybackLabel: remotePlaybackContext == nil
                )
            } catch {
                errorState = AppErrorState(message: error.localizedDescription)
            }
        }
    }
    
    func pickEpisode(_ episode: AnimeEpisode) {
        selectedEpisodeID = episode.id
        if remotePlaybackContext == nil {
            currentEpisodeLabel = episode.displayTitle
        }
        refreshSystemMediaState()
        Task {
            await loadDanmaku(for: episode)
        }
    }
    
    func play() {
        player.play()
    }
    
    func pause() {
        player.pause()
    }
    
    func togglePause() {
        player.togglePause()
    }
    
    func seek(relative seconds: Double) {
        player.seek(relative: seconds)
    }
    
    func seek(to seconds: Double) {
        player.seek(to: seconds)
    }
    
    func selectAudioTrack(id: Int64) {
        selectedAudioTrackID = id
        player.selectAudioTrack(id: id)
    }
    
    func selectSubtitleTrack(id: Int64?) {
        selectedSubtitleTrackID = id
        player.selectSubtitleTrack(id: id)
    }
    
    private func applyJellyfinSnapshot(_ snapshot: JellyfinStoreSnapshot) {
        jellyfinAccounts = snapshot.accounts
        if let activeID = snapshot.activeAccountID, snapshot.accounts.contains(where: { $0.id == activeID }) {
            selectedJellyfinAccountID = activeID
        } else {
            selectedJellyfinAccountID = snapshot.accounts.first?.id
        }
    }
    
    private func clearRemotePlaybackContext() {
        isPlayingRemote = false
        remotePlaybackContext = nil
        previousRemoteEpisode = nil
        nextRemoteEpisode = nil
        currentCollectionTitle = nil
    }
    
    private func clearJellyfinSelectionState() {
        selectedJellyfinItemID = nil
        selectedJellyfinSeasonID = nil
        selectedJellyfinEpisodeID = nil
        jellyfinSeasons = []
        jellyfinEpisodes = []
        previousRemoteEpisode = nil
        nextRemoteEpisode = nil
    }
    
    private func clearJellyfinBrowseState(clearLibraries: Bool) {
        if clearLibraries {
            jellyfinLibraries = []
            selectedJellyfinLibraryID = nil
        }
        jellyfinItems = []
        clearJellyfinSelectionState()
    }
    
    private func resetTrackSelections() {
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
    }
    
    private func jellyfinImageURL(
        itemID: String,
        imageType: String,
        tag: String?,
        width: Int?,
        height: Int?,
        index: Int? = nil,
        quality: Int = 90
    ) -> URL? {
        guard let account = activeJellyfinAccount, let route = activeJellyfinRoute else {
            return nil
        }
        
        var path = "/Items/\(itemID)/Images/\(imageType)"
        if imageType.caseInsensitiveCompare("Backdrop") == .orderedSame {
            path += "/\(index ?? 0)"
        }
        
        guard var components = URLComponents(string: "\(route.normalizedURL)\(path)") else {
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
    
    private func loadJellyfinItems(for libraryID: String, accountID: UUID) async throws {
        jellyfinItems = try await jellyfinClient.loadLibraryItems(accountID: accountID, libraryID: libraryID)
        clearJellyfinSelectionState()
        let snapshot = await jellyfinClient.snapshot()
        applyJellyfinSnapshot(snapshot)
    }
    
    private func loadSeasons(for item: JellyfinMediaItem) async {
        guard let accountID = selectedJellyfinAccountID else { return }
        
        do {
            let seasons = try await jellyfinClient.loadSeasons(accountID: accountID, seriesID: item.id)
            jellyfinSeasons = seasons
            let snapshot = await jellyfinClient.snapshot()
            applyJellyfinSnapshot(snapshot)
            if let firstSeason = seasons.first {
                selectedJellyfinSeasonID = firstSeason.id
                let loadedEpisodes = try await jellyfinClient.loadEpisodes(
                    accountID: accountID,
                    seriesID: item.id,
                    seasonID: firstSeason.id
                )
                jellyfinEpisodes = loadedEpisodes
            } else {
                jellyfinEpisodes = []
            }
        } catch {
            errorState = AppErrorState(message: error.localizedDescription)
        }
    }
    
    private func startJellyfinItemPlayback(_ item: JellyfinMediaItem) async {
        guard let accountID = selectedJellyfinAccountID else { return }
        
        do {
            let session = try await jellyfinClient.createPlaybackSession(accountID: accountID, itemID: item.id)
            let snapshot = await jellyfinClient.snapshot()
            applyJellyfinSnapshot(snapshot)
            selectedJellyfinEpisodeID = nil
            previousRemoteEpisode = nil
            nextRemoteEpisode = nil
            beginRemotePlayback(
                session: session,
                title: item.name,
                episodeLabel: "",
                collectionTitle: nil,
                context: .init(
                    accountID: accountID,
                    itemID: item.id,
                    mediaSourceID: session.mediaSourceID,
                    playSessionID: session.playSessionID,
                    collectionTitle: nil,
                    danmakuQuery: item.name,
                    episodeNumber: nil,
                    seriesID: nil,
                    seasonID: nil,
                    episodeID: nil
                ),
                resumePosition: item.resumePositionSeconds
            )
            searchQuery = item.name
            inferredEpisodeNumber = nil
        } catch {
            errorState = AppErrorState(message: error.localizedDescription)
        }
    }
    
    private func playRemoteEpisode(_ episode: JellyfinEpisode) async {
        guard let accountID = selectedJellyfinAccountID else { return }
        
        do {
            let session = try await jellyfinClient.createPlaybackSession(accountID: accountID, itemID: episode.id)
            let snapshot = await jellyfinClient.snapshot()
            applyJellyfinSnapshot(snapshot)
            selectedJellyfinItemID = episode.seriesID ?? selectedJellyfinItemID
            selectedJellyfinEpisodeID = episode.id
            beginRemotePlayback(
                session: session,
                title: episode.seriesName ?? episode.name,
                episodeLabel: episode.displayTitle,
                collectionTitle: episode.seriesName,
                context: .init(
                    accountID: accountID,
                    itemID: episode.id,
                    mediaSourceID: session.mediaSourceID,
                    playSessionID: session.playSessionID,
                    collectionTitle: episode.seriesName,
                    danmakuQuery: episode.seriesName ?? episode.name,
                    episodeNumber: episode.indexNumber,
                    seriesID: episode.seriesID,
                    seasonID: episode.seasonID,
                    episodeID: episode.id
                ),
                resumePosition: episode.resumePositionSeconds
            )
            searchQuery = episode.seriesName ?? episode.name
            inferredEpisodeNumber = episode.indexNumber
            Task {
                await searchAndAutoloadDanmaku()
            }
            await resolveRemoteEpisodeNeighbors(for: episode)
        } catch {
            errorState = AppErrorState(message: error.localizedDescription)
        }
    }
    
    private func beginRemotePlayback(
        session: JellyfinPlaybackSession,
        title: String,
        episodeLabel: String,
        collectionTitle: String?,
        context: RemotePlaybackContext,
        resumePosition: Double?
    ) {
        currentScopedURL?.stopAccessingSecurityScopedResource()
        currentScopedURL = nil
        currentVideoURL = session.streamURL
        currentVideoTitle = title
        currentEpisodeLabel = episodeLabel
        currentCollectionTitle = collectionTitle
        remotePlaybackContext = context
        isPlayingRemote = true
        danmakuStore.clear()
        resetTrackSelections()
        refreshSystemMediaState()
        player.load(session.streamURL)
        
        if let resumePosition, resumePosition > 1 {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                await MainActor.run {
                    self?.player.seek(to: resumePosition)
                }
            }
        }
    }
    
    private func resolveRemoteEpisodeNeighbors(for episode: JellyfinEpisode) async {
        previousRemoteEpisode = nil
        nextRemoteEpisode = nil
        
        if let index = jellyfinEpisodes.firstIndex(where: { $0.id == episode.id }) {
            if index > 0 {
                previousRemoteEpisode = jellyfinEpisodes[index - 1]
            }
            if jellyfinEpisodes.indices.contains(index + 1) {
                nextRemoteEpisode = jellyfinEpisodes[index + 1]
            }
        }
        
        if previousRemoteEpisode != nil && nextRemoteEpisode != nil {
            refreshSystemMediaState()
            return
        }
        
        guard let accountID = selectedJellyfinAccountID else {
            refreshSystemMediaState()
            return
        }
        
        do {
            let adjacentEpisodes = try await jellyfinClient.loadAdjacentEpisodes(accountID: accountID, episodeID: episode.id)
            if let currentIndex = adjacentEpisodes.firstIndex(where: { $0.id == episode.id }) {
                if previousRemoteEpisode == nil, currentIndex > 0 {
                    previousRemoteEpisode = adjacentEpisodes[currentIndex - 1]
                }
                if nextRemoteEpisode == nil, adjacentEpisodes.indices.contains(currentIndex + 1) {
                    nextRemoteEpisode = adjacentEpisodes[currentIndex + 1]
                }
            }
            let snapshot = await jellyfinClient.snapshot()
            applyJellyfinSnapshot(snapshot)
        } catch {
            // Keep season-local navigation if adjacent lookup fails.
        }
        
        refreshSystemMediaState()
    }
    
    private func loadEpisodes(
        for anime: AnimeSearchResult,
        autoloadDanmaku: Bool,
        updatePlaybackLabel: Bool
    ) async throws {
        let loadedEpisodes = try await dandanplayClient.loadEpisodes(for: anime.id)
        episodes = loadedEpisodes
        
        guard autoloadDanmaku else { return }
        
        let matchingEpisode = loadedEpisodes.first(where: { $0.number == inferredEpisodeNumber }) ?? loadedEpisodes.first
        if let matchingEpisode {
            selectedEpisodeID = matchingEpisode.id
            if updatePlaybackLabel {
                currentEpisodeLabel = matchingEpisode.displayTitle
            }
            refreshSystemMediaState()
            await loadDanmaku(for: matchingEpisode)
        } else {
            refreshSystemMediaState()
        }
    }
    
    private func loadDanmaku(for episode: AnimeEpisode) async {
        isLoadingDanmaku = true
        defer { isLoadingDanmaku = false }
        
        do {
            let comments = try await dandanplayClient.loadDanmaku(episodeID: episode.id)
            danmakuStore.load(comments)
        } catch {
            errorState = AppErrorState(message: error.localizedDescription)
        }
    }
    
    private static func cleanSearchKeyword(from raw: String) -> String {
        var cleaned = raw
        let patterns = [
            #"\[[^\]]*\]"#,
            #"【[^】]*】"#,
            #"\([^)]*\)"#,
            #"（[^）]*）"#,
            #"「[^」]*」"#,
            #"『[^』]*』"#,
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        
        cleaned = cleaned
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let range = cleaned.range(of: #"(?:第?\s*\d{1,3}\s*(?:话|集|話)|ep?\s*\d{1,3})"#, options: [.regularExpression, .caseInsensitive]) {
            cleaned.removeSubrange(range)
        }
        
        return cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func extractEpisodeNumber(from raw: String) -> Int? {
        let pattern = #"(?:第\s*(\d{1,3})\s*[话話集]|ep?\s*(\d{1,3})|[^0-9](\d{1,3})[^0-9]?)"#
        let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = expression?.matches(in: raw, options: [], range: range) ?? []
        
        var candidate: Int?
        for match in matches {
            for index in 1 ..< match.numberOfRanges {
                let groupRange = match.range(at: index)
                guard
                    groupRange.location != NSNotFound,
                    let swiftRange = Range(groupRange, in: raw),
                    let value = Int(raw[swiftRange])
                else {
                    continue
                }
                
                if [4, 264, 265, 480, 720, 1080, 2160].contains(value) {
                    continue
                }
                if value <= 0 || value > 300 {
                    continue
                }
                candidate = value
            }
        }
        return candidate
    }
    
    private static func shouldSurfacePlayerError(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        
        let lowercased = normalized.lowercased()
        if lowercased.contains("mpv_create failed") || lowercased.contains("mpv_initialize failed") {
            return true
        }
        
        if lowercased.hasPrefix("[ffmpeg/") {
            return false
        }
        
        return lowercased.hasPrefix("[cplayer] error:")
            || lowercased.hasPrefix("[file] error:")
            || lowercased.hasPrefix("[stream] error:")
            || lowercased.hasPrefix("[osdep] error:")
    }
    
    private func refreshSystemMediaState() {
        let title = currentEpisodeLabel.isEmpty ? currentVideoTitle : currentEpisodeLabel
        let albumTitle = currentCollectionTitle ?? selectedAnime?.title
        systemMediaController.update(
            metadata: .init(
                title: title,
                albumTitle: albumTitle,
                assetURL: currentVideoURL
            ),
            snapshot: playback,
            active: currentVideoURL != nil,
            canGoToPrevious: canPlayPreviousEpisode,
            canGoToNext: canPlayNextEpisode
        )
    }
}

private struct RemotePlaybackContext {
    var accountID: UUID
    var itemID: String
    var mediaSourceID: String?
    var playSessionID: String?
    var collectionTitle: String?
    var danmakuQuery: String
    var episodeNumber: Int?
    var seriesID: String?
    var seasonID: String?
    var episodeID: String?
}

private final class SystemMediaController {
    struct Metadata: Equatable {
        var title: String
        var albumTitle: String?
        var assetURL: URL?
    }
    
    var onPlay: (@MainActor () -> Void)?
    var onPause: (@MainActor () -> Void)?
    var onTogglePlayPause: (@MainActor () -> Void)?
    var onSeek: (@MainActor (Double) -> Void)?
    var onSkipForward: (@MainActor (Double) -> Void)?
    var onSkipBackward: (@MainActor (Double) -> Void)?
    var onNextTrack: (@MainActor () -> Void)?
    var onPreviousTrack: (@MainActor () -> Void)?
    
    private struct CommandRegistration {
        let command: MPRemoteCommand
        let token: Any
    }
    
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var commandRegistrations: [CommandRegistration] = []
    private var active = false
    private var latestSnapshot = PlaybackSnapshot()
    private var canGoToNextTrack = false
    private var canGoToPreviousTrack = false
    private var lastPublishedMetadata: Metadata?
    private var lastPublishedSnapshot = PlaybackSnapshot()
#if os(iOS)
    private var audioSessionConfigured = false
    private var audioSessionActive = false
#endif
    
    init() {
        configureRemoteCommands()
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.stopCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false
        commandCenter.changeRepeatModeCommand.isEnabled = false
        commandCenter.changeShuffleModeCommand.isEnabled = false
        commandCenter.ratingCommand.isEnabled = false
        commandCenter.likeCommand.isEnabled = false
        commandCenter.dislikeCommand.isEnabled = false
        commandCenter.bookmarkCommand.isEnabled = false
        updateCommandAvailability()
    }
    
    deinit {
        for registration in commandRegistrations {
            registration.command.removeTarget(registration.token)
        }
        clear()
    }
    
    func update(
        metadata: Metadata,
        snapshot: PlaybackSnapshot,
        active: Bool,
        canGoToPrevious: Bool,
        canGoToNext: Bool
    ) {
        let activeChanged = self.active != active
        self.active = active
        latestSnapshot = snapshot
        canGoToPreviousTrack = canGoToPrevious
        canGoToNextTrack = canGoToNext
        updateCommandAvailability()
        
        guard active else {
            if activeChanged || lastPublishedMetadata != nil {
                clear()
            }
            return
        }
        
        updateAudioSession(active: true)
        guard activeChanged || shouldPublishNowPlayingInfo(metadata: metadata, snapshot: snapshot) else {
            return
        }
        publishNowPlayingInfo(metadata: metadata, snapshot: snapshot)
    }
    
    private func configureRemoteCommands() {
        register(commandCenter.playCommand) { [weak self] _ in
            guard let self, self.active else { return .noActionableNowPlayingItem }
            self.invokeOnMain { $0.onPlay?() }
            return .success
        }
        register(commandCenter.pauseCommand) { [weak self] _ in
            guard let self, self.active else { return .noActionableNowPlayingItem }
            self.invokeOnMain { $0.onPause?() }
            return .success
        }
        register(commandCenter.togglePlayPauseCommand) { [weak self] _ in
            guard let self, self.active else { return .noActionableNowPlayingItem }
            self.invokeOnMain { $0.onTogglePlayPause?() }
            return .success
        }
        register(commandCenter.changePlaybackPositionCommand) { [weak self] event in
            guard let self, self.active else { return .noActionableNowPlayingItem }
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.invokeOnMain { $0.onSeek?(event.positionTime) }
            return .success
        }
        register(commandCenter.skipForwardCommand) { [weak self] event in
            guard let self, self.active else { return .noActionableNowPlayingItem }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self.invokeOnMain { $0.onSkipForward?(interval) }
            return .success
        }
        register(commandCenter.skipBackwardCommand) { [weak self] event in
            guard let self, self.active else { return .noActionableNowPlayingItem }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self.invokeOnMain { $0.onSkipBackward?(interval) }
            return .success
        }
        register(commandCenter.nextTrackCommand) { [weak self] _ in
            guard let self, self.active, self.canGoToNextTrack else { return .noActionableNowPlayingItem }
            self.invokeOnMain { $0.onNextTrack?() }
            return .success
        }
        register(commandCenter.previousTrackCommand) { [weak self] _ in
            guard let self, self.active, self.canGoToPreviousTrack else { return .noActionableNowPlayingItem }
            self.invokeOnMain { $0.onPreviousTrack?() }
            return .success
        }
    }
    
    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let token = command.addTarget(handler: handler)
        commandRegistrations.append(CommandRegistration(command: command, token: token))
    }
    
    private func updateCommandAvailability() {
        let canControlPlayback = active
        let canSeek = active && latestSnapshot.duration > 0
        commandCenter.playCommand.isEnabled = canControlPlayback
        commandCenter.pauseCommand.isEnabled = canControlPlayback
        commandCenter.togglePlayPauseCommand.isEnabled = canControlPlayback
        commandCenter.skipForwardCommand.isEnabled = canSeek
        commandCenter.skipBackwardCommand.isEnabled = canSeek
        commandCenter.changePlaybackPositionCommand.isEnabled = canSeek
        commandCenter.nextTrackCommand.isEnabled = active && canGoToNextTrack
        commandCenter.previousTrackCommand.isEnabled = active && canGoToPreviousTrack
    }
    
    private func shouldPublishNowPlayingInfo(metadata: Metadata, snapshot: PlaybackSnapshot) -> Bool {
        guard let lastPublishedMetadata else { return true }
        if metadata != lastPublishedMetadata {
            return true
        }
        if snapshot.loaded != lastPublishedSnapshot.loaded || snapshot.paused != lastPublishedSnapshot.paused {
            return true
        }
        if abs(snapshot.duration - lastPublishedSnapshot.duration) >= 0.5 {
            return true
        }
        
        let positionDelta = abs(snapshot.position - lastPublishedSnapshot.position)
        let positionThreshold = snapshot.paused ? 0.25 : 2.0
        return positionDelta >= positionThreshold
    }
    
    private func publishNowPlayingInfo(metadata: Metadata, snapshot: PlaybackSnapshot) {
        var nowPlayingInfo = infoCenter.nowPlayingInfo ?? [:]
        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata.title
        setOptionalValue(metadata.albumTitle, for: MPMediaItemPropertyAlbumTitle, in: &nowPlayingInfo)
        setOptionalValue(metadata.assetURL, for: MPNowPlayingInfoPropertyAssetURL, in: &nowPlayingInfo)
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = snapshot.position
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = snapshot.loaded && !snapshot.paused ? 1.0 : 0.0
        
        if snapshot.duration > 0 {
            let progress = min(max(snapshot.position / snapshot.duration, 0), 1)
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackProgress] = progress
        } else {
            nowPlayingInfo.removeValue(forKey: MPNowPlayingInfoPropertyPlaybackProgress)
        }
        
        infoCenter.nowPlayingInfo = nowPlayingInfo
        infoCenter.playbackState = {
            guard snapshot.loaded else { return .stopped }
            return snapshot.paused ? .paused : .playing
        }()
        
        lastPublishedMetadata = metadata
        lastPublishedSnapshot = snapshot
    }
    
    private func clear() {
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
        lastPublishedMetadata = nil
        lastPublishedSnapshot = PlaybackSnapshot()
        updateAudioSession(active: false)
    }
    
    private func setOptionalValue(
        _ value: Any?,
        for key: String,
        in dictionary: inout [String: Any]
    ) {
        if let value {
            dictionary[key] = value
        } else {
            dictionary.removeValue(forKey: key)
        }
    }
    
    private func invokeOnMain(_ work: @escaping @MainActor (SystemMediaController) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            work(self)
        }
    }
    
#if os(iOS)
    private func updateAudioSession(active: Bool) {
        let session = AVAudioSession.sharedInstance()
        
        if active {
            if !audioSessionConfigured {
                do {
                    try session.setCategory(.playback, mode: .moviePlayback, options: [])
                    audioSessionConfigured = true
                } catch {
#if DEBUG
                    print("[media] failed to set audio session category: \(error)")
#endif
                }
            }
            
            guard !audioSessionActive else { return }
            do {
                try session.setActive(true)
                audioSessionActive = true
            } catch {
#if DEBUG
                print("[media] failed to activate audio session: \(error)")
#endif
            }
        } else if audioSessionActive {
            do {
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
            } catch {
#if DEBUG
                print("[media] failed to deactivate audio session: \(error)")
#endif
            }
            audioSessionActive = false
        }
    }
#else
    private func updateAudioSession(active _: Bool) {}
#endif
}
