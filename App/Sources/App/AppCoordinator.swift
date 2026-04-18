import Combine
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if os(iOS)
    import Photos
#endif

private struct RemotePlaybackPulse: Equatable {
    var loaded: Bool
    var paused: Bool
    var positionBucket: Int
    var durationBucket: Int
}

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var errorState: AppErrorState?
    @Published private(set) var isCapturingScreenshot = false
    @Published private(set) var screenshotFeedbackMessage: String?

    let playback: PlaybackStore
    let danmaku: DanmakuFeatureStore
    let jellyfin: JellyfinStore

    private var cancellables: Set<AnyCancellable> = []
    private var screenshotFeedbackDismissTask: Task<Void, Never>?

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

        playback.$snapshot
            .map { snapshot in
                RemotePlaybackPulse(
                    loaded: snapshot.loaded,
                    paused: snapshot.paused,
                    positionBucket: Int(snapshot.position.rounded(.down)),
                    durationBucket: Int(snapshot.duration.rounded(.down))
                )
            }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.handleRemotePlaybackPulse()
                }
            }
            .store(in: &cancellables)

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

    var homeJellyfinAccount: JellyfinAccountProfile? {
        jellyfin.homeAccount
    }

    var homeJellyfinRoute: JellyfinRoute? {
        jellyfin.homeRoute
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

    func captureScreenshot() {
        guard !isCapturingScreenshot else { return }
        Task { [weak self] in
            await self?.captureScreenshotAsync()
        }
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

    func jellyfinPosterURL(
        for homeItem: JellyfinHomeItem,
        width: Int = 440,
        height: Int = 660
    ) -> URL? {
        jellyfin.jellyfinPosterURL(for: homeItem, width: width, height: height)
    }

    func jellyfinBackdropURL(
        for homeItem: JellyfinHomeItem,
        width: Int = 1400,
        height: Int = 700
    ) -> URL? {
        jellyfin.jellyfinBackdropURL(
            for: homeItem,
            width: width,
            height: height
        )
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
        finishJellyfinPlaybackIfNeeded(
            finished: shouldTreatCurrentJellyfinPlaybackAsFinished()
        )
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
        guard jellyfin.selectedAccountID != accountID else { return }
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
                self.syncJellyfinNavigation()
            } catch {
                self.handleError(error)
            }
        }
    }

    func useAutomaticJellyfinRouteSelection() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.useAutomaticRouteSelection()
                self.syncJellyfinNavigation()
            } catch {
                self.handleError(error)
            }
        }
    }

    func updateJellyfinRoutePriority(_ routeID: UUID, priority: Int) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.updateRoutePriority(
                    routeID,
                    priority: priority
                )
            } catch {
                self.handleError(error)
            }
        }
    }

    func handleJellyfinAppDidBecomeActive() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.refreshRoutesAfterAppBecomesActive()
                self.syncJellyfinNavigation()
            } catch {
                self.handleError(error)
            }
        }
    }

    func removeSelectedJellyfinAccount() {
        guard let accountID = jellyfin.selectedAccountID else { return }
        removeJellyfinAccount(accountID)
    }

    func removeJellyfinAccount(_ accountID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.removeAccount(accountID)
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

    func refreshJellyfinHome() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.refreshHome()
            } catch {
                self.handleError(error)
            }
        }
    }

    func selectHomeJellyfinAccount(_ accountID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.selectHomeAccount(accountID)
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

    func playJellyfinHomeItem(_ item: JellyfinHomeItem) {
        Task { [weak self] in
            await self?.playJellyfinHomeItemAsync(item)
        }
    }

    func playDownloadedJellyfinEntry(_ entry: JellyfinOfflineEntry) {
        Task { [weak self] in
            await self?.playDownloadedJellyfinEntryAsync(entry)
        }
    }

    func openJellyfinHomeItemInLibrary(_ item: JellyfinHomeItem) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.jellyfin.switchToHomeAccountForBrowsing()
                try await self.jellyfin.focusLibraryContext(for: item)
                self.syncJellyfinNavigation()
            } catch {
                self.handleError(error)
            }
        }
    }

    func setJellyfinHomeItemPlayedState(_ item: JellyfinHomeItem, played: Bool)
    {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.setHomePlayedState(
                    itemID: item.id,
                    played: played
                )
            } catch {
                self.handleError(error)
            }
        }
    }

    func setJellyfinMediaItemPlayedState(
        _ item: JellyfinMediaItem,
        played: Bool
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.setPlayedState(
                    itemID: item.id,
                    played: played
                )
            } catch {
                self.handleError(error)
            }
        }
    }

    func setJellyfinEpisodePlayedState(_ episode: JellyfinEpisode, played: Bool)
    {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.setPlayedState(
                    itemID: episode.id,
                    played: played
                )
            } catch {
                self.handleError(error)
            }
        }
    }

    func setDownloadedJellyfinEntryPlayedState(
        _ entry: JellyfinOfflineEntry,
        played: Bool
    ) {
        jellyfin.setOfflinePlayedState(entryID: entry.id, played: played)
    }

    func removeDownloadedJellyfinEntry(_ entry: JellyfinOfflineEntry) {
        jellyfin.deleteOfflineEntry(entry.id)
        syncJellyfinNavigation()
    }

    func syncDownloadedJellyfinEntries() {
        Task { [weak self] in
            await self?.jellyfin.syncOfflineEntriesIfPossible()
        }
    }

    func resolveDownloadedJellyfinConflict(
        _ entry: JellyfinOfflineEntry,
        preferLocal: Bool
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.resolveOfflineConflict(
                    entryID: entry.id,
                    preferLocal: preferLocal
                )
            } catch {
                self.handleError(error)
            }
        }
    }

    func downloadJellyfinMediaItem(_ item: JellyfinMediaItem) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.queueDownload(for: item)
            } catch {
                self.handleError(error)
            }
        }
    }

    func downloadJellyfinSeason(
        _ season: JellyfinSeason,
        in series: JellyfinMediaItem
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.queueDownload(for: season, in: series)
            } catch {
                self.handleError(error)
            }
        }
    }

    func downloadJellyfinEpisodes(
        _ episodes: [JellyfinEpisode],
        in series: JellyfinMediaItem,
        season: JellyfinSeason?
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.queueDownload(
                    for: episodes,
                    in: series,
                    season: season
                )
            } catch {
                self.handleError(error)
            }
        }
    }

    func downloadJellyfinHomeItem(_ item: JellyfinHomeItem) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jellyfin.queueDownload(for: item)
            } catch {
                self.handleError(error)
            }
        }
    }

    func playPreviousEpisode() {
        if playback.isPlayingRemote,
            let episode = jellyfin.previousRemoteEpisode
        {
            playJellyfinEpisode(episode)
            return
        }
        if let entry = jellyfin.previousOfflineEntry {
            playDownloadedJellyfinEntry(entry)
        }
    }

    func playNextEpisode() {
        if playback.isPlayingRemote, let episode = jellyfin.nextRemoteEpisode {
            playJellyfinEpisode(episode)
            return
        }
        if let entry = jellyfin.nextOfflineEntry {
            playDownloadedJellyfinEntry(entry)
        }
    }

    func handleWindowClosing() {
        finishJellyfinPlaybackIfNeeded(
            finished: shouldTreatCurrentJellyfinPlaybackAsFinished()
        )
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

    func addExternalSubtitle(url: URL) {
        guard playback.currentVideoURL != nil else {
            errorState = AppErrorState(message: "请先开始播放，再挂载外挂字幕。")
            return
        }
        playback.addExternalSubtitle(url)
    }

    private func playJellyfinMediaItemAsync(_ item: JellyfinMediaItem) async {
        do {
            await stopJellyfinPlaybackIfNeeded(
                finished: shouldTreatCurrentJellyfinPlaybackAsFinished()
            )
            let candidate = try await jellyfin.makePlaybackCandidate(for: item)
            playback.beginRemotePlayback(
                session: candidate.session,
                title: candidate.title,
                episodeLabel: candidate.episodeLabel,
                collectionTitle: candidate.collectionTitle,
                resumePosition: candidate.resumePosition,
                externalSubtitles: remoteExternalSubtitleURLs(
                    for: candidate.session
                )
            )
            await jellyfin.beginPlaybackTracking(
                candidate: candidate,
                initialPosition: candidate.resumePosition ?? 0,
                isPaused: false
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
            await stopJellyfinPlaybackIfNeeded(
                finished: shouldTreatCurrentJellyfinPlaybackAsFinished()
            )
            let candidate = try await jellyfin.makePlaybackCandidate(
                for: episode
            )
            playback.beginRemotePlayback(
                session: candidate.session,
                title: candidate.title,
                episodeLabel: candidate.episodeLabel,
                collectionTitle: candidate.collectionTitle,
                resumePosition: candidate.resumePosition,
                externalSubtitles: remoteExternalSubtitleURLs(
                    for: candidate.session
                )
            )
            await jellyfin.beginPlaybackTracking(
                candidate: candidate,
                initialPosition: candidate.resumePosition ?? 0,
                isPaused: false
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

    private func playJellyfinHomeItemAsync(_ item: JellyfinHomeItem) async {
        do {
            await stopJellyfinPlaybackIfNeeded(
                finished: shouldTreatCurrentJellyfinPlaybackAsFinished()
            )
            let candidate = try await jellyfin.makePlaybackCandidate(for: item)
            playback.beginRemotePlayback(
                session: candidate.session,
                title: candidate.title,
                episodeLabel: candidate.episodeLabel,
                collectionTitle: candidate.collectionTitle,
                resumePosition: candidate.resumePosition,
                externalSubtitles: remoteExternalSubtitleURLs(
                    for: candidate.session
                )
            )
            await jellyfin.beginPlaybackTracking(
                candidate: candidate,
                initialPosition: candidate.resumePosition ?? 0,
                isPaused: false
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

    private func playDownloadedJellyfinEntryAsync(_ entry: JellyfinOfflineEntry)
        async
    {
        do {
            await stopJellyfinPlaybackIfNeeded(
                finished: shouldTreatCurrentJellyfinPlaybackAsFinished()
            )
            guard let videoURL = jellyfin.localVideoURL(for: entry) else {
                throw JellyfinClientError.requestFailed("本地下载文件已丢失。")
            }
            playback.openLocalVideo(
                videoURL,
                title: entry.displayTitle,
                episodeLabel: entry.episodeLabel,
                collectionTitle: entry.collectionTitle,
                externalSubtitles: jellyfin.localSubtitleURLs(for: entry)
            )
            jellyfin.beginOfflinePlaybackTracking(entry: entry)
            danmaku.prepareSearch(
                query: entry.seriesTitle ?? entry.title,
                inferredSeasonNumber: entry.seasonNumber,
                inferredSeasonEpisodeCount: nil,
                inferredEpisodeNumber: entry.episodeNumber,
                remoteSeriesID: entry.seriesID,
                remoteSeasonID: entry.seasonID,
                remoteEpisodeID: entry.remoteItemID
            )
            syncJellyfinNavigation()
            if let danmakuURL = jellyfin.localDanmakuURL(for: entry),
                let data = try? Data(contentsOf: danmakuURL),
                let payload = try? JSONDecoder().decode(
                    DanmakuOfflineCachePayload.self,
                    from: data
                )
            {
                danmaku.loadOfflineCache(
                    payload,
                    fallbackQuery: entry.seriesTitle ?? entry.title
                )
                await danmaku.persistCurrentRemoteMappingIfNeeded()
            } else {
                await searchAndAutoloadDanmaku()
            }
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

    private func remoteExternalSubtitleURLs(
        for session: JellyfinPlaybackSession
    ) -> [URL] {
        let selectedSource =
            session.mediaSources.first(where: {
                $0.id == session.mediaSourceID
            })
            ?? session.mediaSources.first
        return selectedSource?.subtitleStreams.compactMap { stream in
            guard stream.isExternal else { return nil }
            return stream.streamURL
        } ?? []
    }

    private func syncJellyfinNavigation() {
        playback.updateNavigation(
            previous: jellyfin.canPlayPreviousEpisode,
            next: jellyfin.canPlayNextEpisode
        )
    }

    private func handleRemotePlaybackPulse() async {
        if playback.isPlayingRemote {
            if playback.snapshot.loaded {
                jellyfin.markActivePlaybackLoaded()
            } else if jellyfin.hasLoadedActivePlayback {
                await stopJellyfinPlaybackIfNeeded(
                    finished: shouldTreatCurrentJellyfinPlaybackAsFinished()
                )
                return
            }

            await jellyfin.reportActivePlaybackProgress(
                positionSeconds: playback.timebase.resolvedPosition(at: Date()),
                durationSeconds: max(
                    playback.snapshot.duration,
                    playback.timebase.duration
                ),
                isPaused: playback.snapshot.paused
            )
            return
        }

        guard jellyfin.hasActiveOfflinePlayback else { return }
        if playback.snapshot.loaded {
            jellyfin.markActiveOfflinePlaybackLoaded()
        } else if jellyfin.hasLoadedActiveOfflinePlayback {
            jellyfin.finishOfflinePlaybackTracking(
                positionSeconds: resolvedOfflinePlaybackPosition(),
                durationSeconds: resolvedOfflinePlaybackDuration(),
                isPaused: playback.snapshot.paused,
                finished: shouldTreatCurrentOfflinePlaybackAsFinished()
            )
            return
        }
        await jellyfin.reportActiveOfflinePlaybackProgress(
            positionSeconds: resolvedOfflinePlaybackPosition(),
            durationSeconds: resolvedOfflinePlaybackDuration(),
            isPaused: playback.snapshot.paused
        )
    }

    private func finishRemotePlaybackIfNeeded(finished: Bool) {
        guard playback.isPlayingRemote else { return }
        let position = playback.timebase.resolvedPosition(at: Date())
        let duration = max(
            playback.snapshot.duration,
            playback.timebase.duration
        )
        let paused = playback.snapshot.paused

        Task { [weak self] in
            await self?.jellyfin.finishPlaybackTracking(
                positionSeconds: position,
                durationSeconds: duration,
                isPaused: paused,
                finished: finished
            )
        }
    }

    private func finishOfflinePlaybackIfNeeded(finished: Bool) {
        guard jellyfin.hasActiveOfflinePlayback else { return }
        jellyfin.finishOfflinePlaybackTracking(
            positionSeconds: resolvedOfflinePlaybackPosition(),
            durationSeconds: resolvedOfflinePlaybackDuration(),
            isPaused: playback.snapshot.paused,
            finished: finished
        )
    }

    private func stopRemotePlaybackIfNeeded(finished: Bool) async {
        guard playback.isPlayingRemote else { return }
        await jellyfin.finishPlaybackTracking(
            positionSeconds: playback.timebase.resolvedPosition(at: Date()),
            durationSeconds: max(
                playback.snapshot.duration,
                playback.timebase.duration
            ),
            isPaused: playback.snapshot.paused,
            finished: finished
        )
    }

    private func stopOfflinePlaybackIfNeeded(finished: Bool) async {
        guard jellyfin.hasActiveOfflinePlayback else { return }
        jellyfin.finishOfflinePlaybackTracking(
            positionSeconds: resolvedOfflinePlaybackPosition(),
            durationSeconds: resolvedOfflinePlaybackDuration(),
            isPaused: playback.snapshot.paused,
            finished: finished
        )
    }

    private func shouldTreatCurrentRemotePlaybackAsFinished() -> Bool {
        guard playback.isPlayingRemote else { return false }

        let duration = max(
            playback.snapshot.duration,
            playback.timebase.duration
        )
        guard duration > 0 else { return false }

        let position = playback.timebase.resolvedPosition(at: Date())
        return position >= max(duration - 30, duration * 0.92)
    }

    private func shouldTreatCurrentOfflinePlaybackAsFinished() -> Bool {
        guard jellyfin.hasActiveOfflinePlayback else { return false }

        let duration = resolvedOfflinePlaybackDuration()
        guard duration > 0 else { return false }

        let position = resolvedOfflinePlaybackPosition()
        return position >= max(duration - 30, duration * 0.92)
    }

    private func resolvedOfflinePlaybackPosition() -> Double {
        if playback.timebase.loaded {
            return playback.timebase.resolvedPosition(at: Date())
        }
        return jellyfin.activeOfflineEntry?.localUserData
            .playbackPositionSeconds
            ?? 0
    }

    private func resolvedOfflinePlaybackDuration() -> Double {
        let playbackDuration = max(
            playback.snapshot.duration,
            playback.timebase.duration
        )
        if playbackDuration > 0 {
            return playbackDuration
        }
        guard let runTimeTicks = jellyfin.activeOfflineEntry?.runTimeTicks
        else {
            return 0
        }
        return runTimeTicks / 10_000_000.0
    }

    private func shouldTreatCurrentJellyfinPlaybackAsFinished() -> Bool {
        if playback.isPlayingRemote {
            return shouldTreatCurrentRemotePlaybackAsFinished()
        }
        if jellyfin.hasActiveOfflinePlayback {
            return shouldTreatCurrentOfflinePlaybackAsFinished()
        }
        return false
    }

    private func finishJellyfinPlaybackIfNeeded(finished: Bool) {
        finishRemotePlaybackIfNeeded(finished: finished)
        finishOfflinePlaybackIfNeeded(finished: finished)
    }

    private func stopJellyfinPlaybackIfNeeded(finished: Bool) async {
        await stopRemotePlaybackIfNeeded(finished: finished)
        await stopOfflinePlaybackIfNeeded(finished: finished)
    }

    private func captureScreenshotAsync() async {
        guard playback.currentVideoURL != nil, playback.snapshot.loaded else {
            errorState = AppErrorState(message: "当前没有可截图的视频。")
            return
        }

        let playbackPosition = resolvedCapturePlaybackPosition()
        isCapturingScreenshot = true
        defer { isCapturingScreenshot = false }

        var temporaryURLs: [URL] = []
        defer {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            let capture = try await playback.captureScreenshot()
            let sourceImage = LoadedScreenshotImage(
                image: capture.image,
                type: nil
            )
            let baseImage = sourceImage.image
            let captureViewport = CGSize(
                width: baseImage.width,
                height: baseImage.height
            )

            let overlay: CGImage?
            if playback.danmakuEnabled {
                overlay = danmaku.makeCaptureOverlay(
                    playbackTime: playbackPosition,
                    viewportSize: captureViewport
                )
            } else {
                overlay = nil
            }

            let finalCaptureURL = try exportScreenshot(
                sourceImage: sourceImage,
                overlay: overlay
            )
            temporaryURLs.append(finalCaptureURL)

            let filename = playback.suggestedCaptureFilename(
                fileExtension: finalCaptureURL.pathExtension,
                positionSeconds: playbackPosition
            )

            #if os(macOS)
                let destinationURL = try saveScreenshotToDesktop(
                    from: finalCaptureURL,
                    filename: filename
                )
                showScreenshotFeedback(
                    "已保存到桌面 · \(destinationURL.lastPathComponent)"
                )
            #else
                try await saveScreenshotToPhotoLibrary(
                    from: finalCaptureURL,
                    filename: filename
                )
                showScreenshotFeedback("已保存到系统相册")
            #endif
        } catch {
            handleError(error)
        }
    }

    private func resolvedCapturePlaybackPosition() -> Double {
        if playback.timebase.loaded {
            return playback.timebase.resolvedPosition(at: Date())
        }
        return playback.snapshot.position
    }

    private func exportScreenshot(
        sourceImage: LoadedScreenshotImage,
        overlay: CGImage?
    ) throws -> URL {
        let outputColorSpace =
            sourceImage.image.colorSpace
            ?? CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpaceCreateDeviceRGB()
        let outputFormats = resolvedScreenshotExportFormats(
            for: sourceImage.image,
            sourceType: sourceImage.type,
            hasOverlay: overlay != nil
        )

        let baseCIImage = CIImage(
            cgImage: sourceImage.image,
            options: [.colorSpace: outputColorSpace]
        )
        let finalCIImage: CIImage
        if let overlay {
            let overlayColorSpace =
                CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            let overlayCIImage = CIImage(
                cgImage: overlay,
                options: [.colorSpace: overlayColorSpace]
            )
            finalCIImage = overlayCIImage.composited(over: baseCIImage)
        } else {
            finalCIImage = baseCIImage
        }

        let context = CIContext(
            options: [
                .cacheIntermediates: false,
                .workingColorSpace: outputColorSpace,
                .outputColorSpace: outputColorSpace,
            ]
        )
        var lastError: Error?
        for outputFormat in outputFormats {
            do {
                return try writeScreenshotImage(
                    finalCIImage,
                    colorSpace: outputColorSpace,
                    format: outputFormat,
                    context: context
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? ScreenshotCaptureError.exportFailed
    }

    private func resolvedScreenshotExportFormats(
        for image: CGImage,
        sourceType: UTType?,
        hasOverlay: Bool
    ) -> [ScreenshotExportFormat] {
        let isHDR =
            image.colorSpace.map(Self.isHDRScreenshotColorSpace(_:)) ?? false
        return ScreenshotExportFormat.preferredFormats(
            isHDR: isHDR,
            sourceType: sourceType,
            hasOverlay: hasOverlay
        )
        .filter(Self.supportsScreenshotExportFormat(_:))
    }

    private func writeScreenshotImage(
        _ image: CIImage,
        colorSpace: CGColorSpace,
        format: ScreenshotExportFormat,
        context: CIContext
    ) throws -> URL {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension(format.fileExtension)

        do {
            switch format {
            case .png:
                try context.writePNGRepresentation(
                    of: image,
                    to: destinationURL,
                    format: .RGBA16,
                    colorSpace: colorSpace,
                    options: [:]
                )
            case .jpegXL:
                guard #available(macOS 15.2, iOS 18.2, *) else {
                    throw ScreenshotCaptureError.exportFailed
                }
                guard
                    let cgImage = context.createCGImage(
                        image,
                        from: image.extent.integral,
                        format: .RGBA16,
                        colorSpace: colorSpace
                    )
                else {
                    throw ScreenshotCaptureError.exportFailed
                }
                try writeImageDestination(
                    cgImage,
                    to: destinationURL,
                    type: UTType.jpegxl,
                    properties: [
                        kCGImageDestinationLossyCompressionQuality: 1.0
                    ]
                )
            case .heifLossless:
                let options: [CIImageRepresentationOption: Any] = [
                    CIImageRepresentationOption(
                        rawValue: kCGImageDestinationLossyCompressionQuality
                            as String
                    ): 1.0
                ]
                try context.writeHEIFRepresentation(
                    of: image,
                    to: destinationURL,
                    format: .RGBA16,
                    colorSpace: colorSpace,
                    options: options
                )
            case .heif10:
                let options: [CIImageRepresentationOption: Any] = [
                    CIImageRepresentationOption(
                        rawValue: kCGImageDestinationLossyCompressionQuality
                            as String
                    ): 1.0
                ]
                try context.writeHEIF10Representation(
                    of: image,
                    to: destinationURL,
                    colorSpace: colorSpace,
                    options: options
                )
            case .tiff:
                try context.writeTIFFRepresentation(
                    of: image,
                    to: destinationURL,
                    format: .RGBA16,
                    colorSpace: colorSpace,
                    options: [:]
                )
            }
            return destinationURL
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func writeImageDestination(
        _ image: CGImage,
        to url: URL,
        type: UTType,
        properties: [CFString: Any]
    ) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                type.identifier as CFString,
                1,
                nil
            )
        else {
            throw ScreenshotCaptureError.exportFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotCaptureError.exportFailed
        }
    }

    #if os(macOS)
        private func saveScreenshotToDesktop(
            from sourceURL: URL,
            filename: String
        ) throws -> URL {
            guard
                let desktopURL = FileManager.default.urls(
                    for: .desktopDirectory,
                    in: .userDomainMask
                ).first
            else {
                throw ScreenshotCaptureError.desktopUnavailable
            }

            let destinationURL = uniqueScreenshotURL(
                in: desktopURL,
                preferredFilename: filename
            )
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }
    #else
        private func saveScreenshotToPhotoLibrary(
            from sourceURL: URL,
            filename: String
        ) async throws {
            let authorizationStatus =
                await withCheckedContinuation { continuation in
                    PHPhotoLibrary.requestAuthorization(for: .addOnly) {
                        continuation.resume(returning: $0)
                    }
                }
            guard
                authorizationStatus == .authorized
                    || authorizationStatus == .limited
            else {
                throw ScreenshotCaptureError.photoLibraryPermissionDenied
            }

            let typeIdentifier =
                UTType(filenameExtension: sourceURL.pathExtension)?.identifier
                ?? UTType.png.identifier

            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = filename
                    options.uniformTypeIdentifier = typeIdentifier
                    request.addResource(
                        with: .photo,
                        fileURL: sourceURL,
                        options: options
                    )
                }) { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(
                            throwing: ScreenshotCaptureError
                                .photoLibrarySaveFailed
                        )
                    }
                }
            }
        }
    #endif

    private func uniqueScreenshotURL(
        in directoryURL: URL,
        preferredFilename: String
    ) -> URL {
        let preferredURL = directoryURL.appendingPathComponent(
            preferredFilename,
            isDirectory: false
        )
        guard !FileManager.default.fileExists(atPath: preferredURL.path) else {
            let baseName = preferredURL.deletingPathExtension()
                .lastPathComponent
            let fileExtension = preferredURL.pathExtension
            for index in 1...999 {
                let candidateURL = directoryURL.appendingPathComponent(
                    "\(baseName)-\(index).\(fileExtension)",
                    isDirectory: false
                )
                if !FileManager.default.fileExists(atPath: candidateURL.path) {
                    return candidateURL
                }
            }
            return directoryURL.appendingPathComponent(
                "\(baseName)-\(UUID().uuidString.prefix(8)).\(fileExtension)",
                isDirectory: false
            )
        }
        return preferredURL
    }

    private func showScreenshotFeedback(_ message: String) {
        screenshotFeedbackDismissTask?.cancel()
        screenshotFeedbackMessage = message
        screenshotFeedbackDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                self?.screenshotFeedbackMessage = nil
            }
        }
    }

    private func handleError(_ error: Error) {
        errorState = AppErrorState(message: error.localizedDescription)
    }

    private static func supportsScreenshotExportFormat(
        _ format: ScreenshotExportFormat
    ) -> Bool {
        switch format {
        case .png, .heifLossless, .heif10, .tiff:
            return true
        case .jpegXL:
            guard #available(macOS 15.2, iOS 18.2, *) else { return false }
            let supportedTypes =
                CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            return supportedTypes.contains(UTType.jpegxl.identifier)
        }
    }

    private static func isHDRScreenshotColorSpace(_ colorSpace: CGColorSpace)
        -> Bool
    {
        if CGColorSpaceUsesITUR_2100TF(colorSpace)
            || CGColorSpaceIsPQBased(colorSpace)
            || CGColorSpaceIsHLGBased(colorSpace)
        {
            return true
        }

        let extendedNames: Set<CFString> = [
            CGColorSpace.extendedSRGB,
            CGColorSpace.extendedLinearSRGB,
            CGColorSpace.extendedLinearDisplayP3,
            CGColorSpace.extendedITUR_2020,
            CGColorSpace.extendedLinearITUR_2020,
            CGColorSpace.displayP3_PQ,
            CGColorSpace.displayP3_HLG,
            CGColorSpace.itur_2100_PQ,
            CGColorSpace.itur_2100_HLG,
        ]
        return colorSpace.name.map { extendedNames.contains($0) } ?? false
    }
}

private struct LoadedScreenshotImage {
    let image: CGImage
    let type: UTType?
}

private enum ScreenshotExportFormat: Equatable {
    case png
    case jpegXL
    case heifLossless
    case heif10
    case tiff

    var fileExtension: String {
        switch self {
        case .png:
            return "png"
        case .jpegXL:
            return "jxl"
        case .heifLossless, .heif10:
            return "heic"
        case .tiff:
            return "tiff"
        }
    }

    static func preferredFormats(
        isHDR: Bool,
        sourceType: UTType?,
        hasOverlay: Bool
    ) -> [ScreenshotExportFormat] {
        if isHDR {
            if !hasOverlay,
                sourceType == .png
            {
                return [.heif10, .jpegXL, .heifLossless, .tiff, .png]
            }
            return [.heif10, .jpegXL, .heifLossless, .tiff, .png]
        }

        if !hasOverlay,
            sourceType == .png
        {
            return [.png, .jpegXL, .heifLossless, .tiff]
        }
        return [.png, .jpegXL, .heifLossless, .tiff]
    }
}

private enum ScreenshotCaptureError: LocalizedError {
    case exportFailed
    case desktopUnavailable
    case photoLibraryPermissionDenied
    case photoLibrarySaveFailed

    var errorDescription: String? {
        switch self {
        case .exportFailed:
            return "截图导出失败。"
        case .desktopUnavailable:
            return "无法定位桌面目录。"
        case .photoLibraryPermissionDenied:
            return "没有系统相册写入权限。"
        case .photoLibrarySaveFailed:
            return "保存到系统相册失败。"
        }
    }
}
