import Combine
import Foundation

@MainActor
final class PlaybackStore: ObservableObject {
    private static let preferencesDefaultsKey =
        "starmine.playback.preferences.v1"

    @Published var snapshot = PlaybackSnapshot()
    @Published private(set) var timebase = PlaybackTimebase()
    @Published var currentVideoURL: URL?
    @Published var currentVideoTitle = "Starmine"
    @Published var currentEpisodeLabel = ""
    @Published var currentCollectionTitle: String?
    @Published var fallbackCollectionTitle: String?
    @Published var danmakuEnabled = true
    @Published var audioTracks: [MediaTrackOption] = []
    @Published var subtitleTracks: [MediaTrackOption] = []
    @Published var selectedAudioTrackID: Int64?
    @Published var selectedSubtitleTrackID: Int64?
    @Published var spatialAudioEnabled = false
    @Published var isPlayingRemote = false
    @Published var canPlayPreviousEpisode = false
    @Published var canPlayNextEpisode = false
    @Published var preferences: PlaybackPreferences {
        didSet {
            let clampedPreferences = preferences.clamped()
            if clampedPreferences != preferences {
                preferences = clampedPreferences
                return
            }
            persistPreferences()
            applyPreferences()
        }
    }

    let player = MPVPlayerController()

    var onPlayerError: ((String) -> Void)?
    var onNextTrack: (() -> Void)?
    var onPreviousTrack: (() -> Void)?

    private let systemMediaController = SystemMediaController()
    private let userDefaults: UserDefaults
    private var currentScopedURL: URL?
    private var currentScopedSubtitleURLs: [URL] = []

    init(userDefaults: UserDefaults = .standard) {
        let preferences = Self.loadPreferences(userDefaults: userDefaults)
        self.preferences = preferences
        self.userDefaults = userDefaults

        player.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            let now = Date()
            let previousSnapshot = self.snapshot
            self.snapshot = snapshot
            self.timebase = PlaybackTimebase.reconciled(
                from: self.timebase,
                previousSnapshot: previousSnapshot,
                snapshot: snapshot,
                at: now
            )
            self.refreshSystemMediaState()
        }
        player.onLogMessage = { [weak self] message in
            #if DEBUG
                print("[mpv] \(message)")
            #endif
            if Self.shouldSurfacePlayerError(message) {
                self?.onPlayerError?(message)
            }
        }
        player.onTrackState = { [weak self] trackState in
            self?.audioTracks = trackState.audioTracks
            self?.subtitleTracks = trackState.subtitleTracks
            self?.selectedAudioTrackID = trackState.selectedAudioID
            self?.selectedSubtitleTrackID = trackState.selectedSubtitleID
            self?.reconcileSpatialAudioState()
            self?.refreshSystemMediaState()
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
            self?.onNextTrack?()
        }
        systemMediaController.onPreviousTrack = { [weak self] in
            self?.onPreviousTrack?()
        }
        applyPreferences()
        refreshSystemMediaState()
    }

    deinit {
        currentScopedURL?.stopAccessingSecurityScopedResource()
        for url in currentScopedSubtitleURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    var selectedAudioTrack: MediaTrackOption? {
        audioTracks.first(where: { $0.mpvID == selectedAudioTrackID })
    }

    var selectedSubtitleTrack: MediaTrackOption? {
        subtitleTracks.first(where: { $0.mpvID == selectedSubtitleTrackID })
    }

    var selectedSpatialAudioDecoder: SpatialAudioDecoder? {
        selectedAudioTrack?.spatialAudioDecoder
    }

    var canEnableSpatialAudio: Bool {
        selectedSpatialAudioDecoder != nil
    }

    func openLocalVideo(
        _ url: URL,
        title: String? = nil,
        episodeLabel: String = "",
        collectionTitle: String? = nil,
        externalSubtitles: [URL] = []
    ) {
        currentScopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() {
            currentScopedURL = url
        } else {
            currentScopedURL = nil
        }
        stopAccessingScopedSubtitleURLs()
        beginAccessingScopedSubtitleURLs(externalSubtitles)

        isPlayingRemote = false
        currentVideoURL = url
        currentVideoTitle = title ?? url.lastPathComponent
        currentEpisodeLabel = episodeLabel
        currentCollectionTitle = collectionTitle
        fallbackCollectionTitle = nil
        resetTrackSelections()
        updateNavigation(previous: false, next: false)
        refreshSystemMediaState()
        player.load(url, externalSubtitles: externalSubtitles)
    }

    func beginRemotePlayback(
        session: JellyfinPlaybackSession,
        title: String,
        episodeLabel: String,
        collectionTitle: String?,
        resumePosition: Double?,
        externalSubtitles: [URL] = []
    ) {
        currentScopedURL?.stopAccessingSecurityScopedResource()
        currentScopedURL = nil
        stopAccessingScopedSubtitleURLs()
        currentVideoURL = session.streamURL
        currentVideoTitle = title
        currentEpisodeLabel = episodeLabel
        currentCollectionTitle = collectionTitle
        fallbackCollectionTitle = nil
        isPlayingRemote = true
        resetTrackSelections()
        refreshSystemMediaState()
        player.load(session.streamURL, externalSubtitles: externalSubtitles)

        if let resumePosition, resumePosition > 1 {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                await MainActor.run {
                    self?.player.seek(to: resumePosition)
                }
            }
        }
    }

    func setEpisodeLabel(_ label: String) {
        currentEpisodeLabel = label
        refreshSystemMediaState()
    }

    func setFallbackCollectionTitle(_ title: String?) {
        fallbackCollectionTitle = title
        refreshSystemMediaState()
    }

    func updateNavigation(previous: Bool, next: Bool) {
        canPlayPreviousEpisode = previous
        canPlayNextEpisode = next
        refreshSystemMediaState()
    }

    func stopPlayback() {
        player.stop()
        currentScopedURL?.stopAccessingSecurityScopedResource()
        currentScopedURL = nil
        stopAccessingScopedSubtitleURLs()
        snapshot = PlaybackSnapshot()
        timebase = PlaybackTimebase()
        currentVideoURL = nil
        currentVideoTitle = "Starmine"
        currentEpisodeLabel = ""
        currentCollectionTitle = nil
        fallbackCollectionTitle = nil
        isPlayingRemote = false
        resetTrackSelections()
        canPlayPreviousEpisode = false
        canPlayNextEpisode = false
        refreshSystemMediaState()
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

    func setPlaybackRate(_ rate: Double) {
        preferences.playbackRate = rate
    }

    func setSeekInterval(_ seconds: Double) {
        preferences.seekInterval = seconds
    }

    func selectAudioTrack(id: Int64) {
        selectedAudioTrackID = id
        player.selectAudioTrack(id: id)
        reconcileSpatialAudioState()
    }

    func setSpatialAudioEnabled(_ enabled: Bool) {
        let nextValue = enabled && canEnableSpatialAudio
        guard spatialAudioEnabled != nextValue else { return }
        spatialAudioEnabled = nextValue
        applySpatialAudioMode()
    }

    func selectSubtitleTrack(id: Int64?) {
        selectedSubtitleTrackID = id
        player.selectSubtitleTrack(id: id)
    }

    func addExternalSubtitle(_ url: URL) {
        beginAccessingScopedSubtitleURLs([url])
        player.addExternalSubtitle(url)
    }

    func captureScreenshot() async throws -> PlayerScreenshotCapture {
        try await player.captureScreenshot()
    }

    func suggestedCaptureFilename(
        fileExtension: String,
        positionSeconds: Double
    ) -> String {
        PlaybackCaptureNaming.filename(
            title: currentVideoTitle,
            episodeLabel: currentEpisodeLabel,
            collectionTitle: currentCollectionTitle,
            assetURL: currentVideoURL,
            positionSeconds: positionSeconds,
            fileExtension: fileExtension
        )
    }

    static func shouldSurfacePlayerError(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let lowercased = normalized.lowercased()
        if lowercased.contains("mpv_create failed")
            || lowercased.contains("mpv_initialize failed")
        {
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

    private func resetTrackSelections() {
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        spatialAudioEnabled = false
        applySpatialAudioMode()
    }

    private func reconcileSpatialAudioState() {
        if spatialAudioEnabled && !canEnableSpatialAudio {
            spatialAudioEnabled = false
        }
        applySpatialAudioMode()
    }

    private func applySpatialAudioMode() {
        let decoder =
            spatialAudioEnabled && canEnableSpatialAudio
            ? selectedSpatialAudioDecoder
            : nil
        player.setSpatialAudioEnabled(
            spatialAudioEnabled && canEnableSpatialAudio,
            decoder: decoder
        )
    }

    private func beginAccessingScopedSubtitleURLs(_ urls: [URL]) {
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                currentScopedSubtitleURLs.append(url)
            }
        }
    }

    private func stopAccessingScopedSubtitleURLs() {
        for url in currentScopedSubtitleURLs {
            url.stopAccessingSecurityScopedResource()
        }
        currentScopedSubtitleURLs.removeAll()
    }

    private func refreshSystemMediaState() {
        let title =
            currentEpisodeLabel.isEmpty
            ? currentVideoTitle : currentEpisodeLabel
        let albumTitle = currentCollectionTitle ?? fallbackCollectionTitle
        systemMediaController.update(
            metadata: .init(
                title: title,
                albumTitle: albumTitle,
                assetURL: currentVideoURL
            ),
            snapshot: snapshot,
            active: currentVideoURL != nil,
            canGoToPrevious: canPlayPreviousEpisode,
            canGoToNext: canPlayNextEpisode,
            skipInterval: preferences.seekInterval
        )
    }

    private func applyPreferences() {
        player.setPlaybackRate(preferences.playbackRate)
        refreshSystemMediaState()
    }

    private func persistPreferences() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(preferences) else { return }
        userDefaults.set(data, forKey: Self.preferencesDefaultsKey)
    }

    private static func loadPreferences(userDefaults: UserDefaults)
        -> PlaybackPreferences
    {
        guard
            let data = userDefaults.data(forKey: Self.preferencesDefaultsKey),
            let preferences = try? JSONDecoder().decode(
                PlaybackPreferences.self,
                from: data
            )
        else {
            return .default
        }

        return preferences.clamped()
    }
}
