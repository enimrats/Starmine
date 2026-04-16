import Combine
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var errorState: AppErrorState?

    let playback: PlaybackStore
    let danmaku: DanmakuFeatureStore
    let jellyfin: JellyfinStore

    private var cancellables: Set<AnyCancellable> = []

    convenience init() {
        self.init(
            playback: PlaybackStore(),
            danmaku: DanmakuFeatureStore(),
            jellyfin: JellyfinStore()
        )
    }

    init(
        playback: PlaybackStore,
        danmaku: DanmakuFeatureStore,
        jellyfin: JellyfinStore
    ) {
        self.playback = playback
        self.danmaku = danmaku
        self.jellyfin = jellyfin

        [
            danmaku.objectWillChange.eraseToAnyPublisher(),
            jellyfin.objectWillChange.eraseToAnyPublisher(),
        ]
        .forEach { publisher in
            publisher
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }

        playback.onPlayerError = { [weak self] message in
            self?.errorState = AppErrorState(message: message)
        }
        playback.onNextTrack = { [weak self] in
            self?.playNextEpisode()
        }
        playback.onPreviousTrack = { [weak self] in
            self?.playPreviousEpisode()
        }

        Task { [weak self] in
            await self?.restoreJellyfinState()
        }
    }

    var selectedAnime: AnimeSearchResult? {
        danmaku.selectedAnime
    }

    var selectedEpisode: AnimeEpisode? {
        danmaku.selectedEpisode
    }

    var selectedAudioTrack: MediaTrackOption? {
        playback.selectedAudioTrack
    }

    var selectedSubtitleTrack: MediaTrackOption? {
        playback.selectedSubtitleTrack
    }

    var activeJellyfinAccount: JellyfinAccountProfile? {
        jellyfin.activeAccount
    }

    var activeJellyfinRoute: JellyfinRoute? {
        jellyfin.activeRoute
    }

    var selectedJellyfinLibrary: JellyfinLibrary? {
        jellyfin.selectedLibrary
    }

    var selectedJellyfinItem: JellyfinMediaItem? {
        jellyfin.selectedItem
    }

    var selectedJellyfinSeason: JellyfinSeason? {
        jellyfin.selectedSeason
    }

    var selectedJellyfinEpisode: JellyfinEpisode? {
        jellyfin.selectedEpisode
    }

    var canPlayPreviousEpisode: Bool {
        playback.canPlayPreviousEpisode
    }

    var canPlayNextEpisode: Bool {
        playback.canPlayNextEpisode
    }

    func jellyfinLibraryImageURL(
        _ library: JellyfinLibrary,
        width: Int = 320,
        height: Int = 190
    ) -> URL? {
        jellyfin.jellyfinLibraryImageURL(library, width: width, height: height)
    }

    func jellyfinPosterURL(
        for item: JellyfinMediaItem,
        width: Int = 440,
        height: Int = 660
    ) -> URL? {
        jellyfin.jellyfinPosterURL(for: item, width: width, height: height)
    }

    func jellyfinBackdropURL(
        for item: JellyfinMediaItem,
        width: Int = 1400,
        height: Int = 700
    ) -> URL? {
        jellyfin.jellyfinBackdropURL(for: item, width: width, height: height)
    }

    func jellyfinPosterURL(
        for season: JellyfinSeason,
        width: Int = 320,
        height: Int = 480
    ) -> URL? {
        jellyfin.jellyfinPosterURL(for: season, width: width, height: height)
    }

    func jellyfinEpisodeThumbnailURL(
        _ episode: JellyfinEpisode,
        width: Int = 480,
        height: Int = 270
    ) -> URL? {
        jellyfin.jellyfinEpisodeThumbnailURL(
            episode,
            width: width,
            height: height
        )
    }

    func openVideo(url: URL) {
        playback.openLocalVideo(url)
        jellyfin.clearRemoteNavigation()

        let rawTitle = url.deletingPathExtension().lastPathComponent
        let inferredSeasonNumber =
            DandanplaySearchHeuristics.extractSeasonNumber(from: rawTitle)
        let inferredEpisodeNumber =
            DandanplaySearchHeuristics.extractEpisodeNumber(from: rawTitle)
        let cleanedTitle = DandanplaySearchHeuristics.cleanSearchKeyword(
            from: rawTitle
        )
        danmaku.prepareSearch(
            query: cleanedTitle,
            inferredSeasonNumber: inferredSeasonNumber,
            inferredSeasonEpisodeCount: nil,
            inferredEpisodeNumber: inferredEpisodeNumber
        )

        Task { [weak self] in
            await self?.searchAndAutoloadDanmaku()
        }
    }

    func restoreJellyfinState() async {
        do {
            try await jellyfin.restoreState()
            syncJellyfinNavigation()
        } catch {
            handleError(error)
        }
    }

    func connectJellyfin(
        serverURL: String,
        username: String,
        password: String,
        routeName: String?
    ) async -> Bool {
        do {
            try await jellyfin.connect(
                serverURL: serverURL,
                username: username,
                password: password,
                routeName: routeName
            )
            return true
        } catch {
            handleError(error)
            return false
        }
    }

    func addJellyfinRoute(serverURL: String, routeName: String?) async -> Bool {
        do {
            try await jellyfin.addRoute(
                serverURL: serverURL,
                routeName: routeName
            )
            return true
        } catch {
            handleError(error)
            return false
        }
    }

    func switchJellyfinAccount(_ accountID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.switchAccount(accountID)
                self.syncJellyfinNavigation()
            } catch {
                self.handleError(error)
            }
        }
    }

    func switchJellyfinRoute(_ routeID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.switchRoute(routeID)
            } catch {
                self.handleError(error)
            }
        }
    }

    func removeSelectedJellyfinAccount() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.removeSelectedAccount()
                self.syncJellyfinNavigation()
            } catch {
                self.handleError(error)
            }
        }
    }

    func refreshJellyfinLibrary() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.refreshLibrary()
            } catch {
                self.handleError(error)
            }
        }
    }

    func selectJellyfinLibrary(_ library: JellyfinLibrary) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.selectLibrary(library)
            } catch {
                self.handleError(error)
            }
        }
    }

    func selectJellyfinItem(_ item: JellyfinMediaItem) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.selectItem(item)
                self.syncJellyfinNavigation()
            } catch {
                self.handleError(error)
            }
        }
    }

    func selectJellyfinSeason(_ season: JellyfinSeason) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.selectSeason(season)
                self.syncJellyfinNavigation()
            } catch {
                self.handleError(error)
            }
        }
    }

    func clearSelectedJellyfinItem() {
        jellyfin.clearSelectedItem()
        syncJellyfinNavigation()
    }

    func playJellyfinMediaItem(_ item: JellyfinMediaItem) {
        Task { [weak self] in
            await self?.playJellyfinMediaItemAsync(item)
        }
    }

    func playJellyfinEpisode(_ episode: JellyfinEpisode) {
        Task { [weak self] in
            await self?.playJellyfinEpisodeAsync(episode)
        }
    }

    func playPreviousEpisode() {
        guard let episode = jellyfin.previousRemoteEpisode else { return }
        playJellyfinEpisode(episode)
    }

    func playNextEpisode() {
        guard let episode = jellyfin.nextRemoteEpisode else { return }
        playJellyfinEpisode(episode)
    }

    func handleWindowClosing() {
        playback.stopPlayback()
    }

    func searchAndAutoloadDanmaku() async {
        do {
            let matchingEpisode = try await danmaku.searchAndAutoloadDanmaku()
            syncDanmakuSelection(
                updatePlaybackLabel: !playback.isPlayingRemote,
                matchingEpisode: matchingEpisode
            )
        } catch {
            handleError(error)
        }
    }

    func pickAnime(_ anime: AnimeSearchResult) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let matchingEpisode = try await self.danmaku.pickAnime(anime)
                self.syncDanmakuSelection(
                    updatePlaybackLabel: !self.playback.isPlayingRemote,
                    matchingEpisode: matchingEpisode
                )
            } catch {
                self.handleError(error)
            }
        }
    }

    func pickEpisode(_ episode: AnimeEpisode) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.danmaku.pickEpisode(episode)
                if !self.playback.isPlayingRemote {
                    self.playback.setEpisodeLabel(episode.displayTitle)
                }
                self.syncDanmakuSelection(
                    updatePlaybackLabel: false,
                    matchingEpisode: episode
                )
            } catch {
                self.handleError(error)
            }
        }
    }

    func play() {
        playback.play()
    }

    func pause() {
        playback.pause()
    }

    func togglePause() {
        playback.togglePause()
    }

    func seek(relative seconds: Double) {
        playback.seek(relative: seconds)
    }

    func seek(to seconds: Double) {
        playback.seek(to: seconds)
    }

    func selectAudioTrack(id: Int64) {
        playback.selectAudioTrack(id: id)
    }

    func selectSubtitleTrack(id: Int64?) {
        playback.selectSubtitleTrack(id: id)
    }

    private func playJellyfinMediaItemAsync(_ item: JellyfinMediaItem) async {
        do {
            let candidate = try await jellyfin.makePlaybackCandidate(for: item)
            playback.beginRemotePlayback(
                session: candidate.session,
                title: candidate.title,
                episodeLabel: candidate.episodeLabel,
                collectionTitle: candidate.collectionTitle,
                resumePosition: candidate.resumePosition
            )
            danmaku.prepareSearch(
                query: candidate.danmakuQuery,
                inferredSeasonNumber: candidate.seasonNumber,
                inferredSeasonEpisodeCount: candidate.seasonEpisodeCount,
                inferredEpisodeNumber: candidate.episodeNumber,
                remoteSeriesID: candidate.remoteSeriesID,
                remoteSeasonID: candidate.remoteSeasonID,
                remoteEpisodeID: candidate.remoteEpisodeID
            )
            syncJellyfinNavigation()
            await searchAndAutoloadDanmaku()
        } catch {
            handleError(error)
        }
    }

    private func playJellyfinEpisodeAsync(_ episode: JellyfinEpisode) async {
        do {
            let candidate = try await jellyfin.makePlaybackCandidate(
                for: episode
            )
            playback.beginRemotePlayback(
                session: candidate.session,
                title: candidate.title,
                episodeLabel: candidate.episodeLabel,
                collectionTitle: candidate.collectionTitle,
                resumePosition: candidate.resumePosition
            )
            danmaku.prepareSearch(
                query: candidate.danmakuQuery,
                inferredSeasonNumber: candidate.seasonNumber,
                inferredSeasonEpisodeCount: candidate.seasonEpisodeCount,
                inferredEpisodeNumber: candidate.episodeNumber,
                remoteSeriesID: candidate.remoteSeriesID,
                remoteSeasonID: candidate.remoteSeasonID,
                remoteEpisodeID: candidate.remoteEpisodeID
            )
            syncJellyfinNavigation()
            await searchAndAutoloadDanmaku()
        } catch {
            handleError(error)
        }
    }

    private func syncDanmakuSelection(
        updatePlaybackLabel: Bool,
        matchingEpisode: AnimeEpisode?
    ) {
        playback.setFallbackCollectionTitle(danmaku.selectedAnime?.title)
        if updatePlaybackLabel, let matchingEpisode {
            playback.setEpisodeLabel(matchingEpisode.displayTitle)
        }
    }

    private func syncJellyfinNavigation() {
        playback.updateNavigation(
            previous: jellyfin.canPlayPreviousEpisode,
            next: jellyfin.canPlayNextEpisode
        )
    }

    private func handleError(_ error: Error) {
        errorState = AppErrorState(message: error.localizedDescription)
    }
}
