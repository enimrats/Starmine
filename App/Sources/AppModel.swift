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
    @Published var errorState: AppErrorState?
    
    let player = MPVPlayerController()
    let danmakuStore = DanmakuOverlayStore()
    
    private let dandanplayClient = DandanplayClient()
    private let systemMediaController = SystemMediaController()
    private var currentScopedURL: URL?
    private var inferredEpisodeNumber: Int?
    
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
        refreshSystemMediaState()
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
    
    func openVideo(url: URL) {
        currentScopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() {
            currentScopedURL = url
        } else {
            currentScopedURL = nil
        }
        
        currentVideoURL = url
        currentVideoTitle = url.lastPathComponent
        currentEpisodeLabel = ""
        searchResults = []
        selectedAnimeID = nil
        episodes = []
        danmakuStore.clear()
        selectedEpisodeID = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        refreshSystemMediaState()
        player.load(url)
        
        let cleanedTitle = Self.cleanSearchKeyword(from: url.deletingPathExtension().lastPathComponent)
        searchQuery = cleanedTitle
        inferredEpisodeNumber = Self.extractEpisodeNumber(from: cleanedTitle)
        
        Task {
            await searchAndAutoloadDanmaku()
        }
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
            try await loadEpisodes(for: bestMatch, autoloadDanmaku: true)
        } catch {
            errorState = AppErrorState(message: error.localizedDescription)
        }
    }
    
    func pickAnime(_ anime: AnimeSearchResult) {
        selectedAnimeID = anime.id
        refreshSystemMediaState()
        Task {
            do {
                try await loadEpisodes(for: anime, autoloadDanmaku: true)
            } catch {
                errorState = AppErrorState(message: error.localizedDescription)
            }
        }
    }
    
    func pickEpisode(_ episode: AnimeEpisode) {
        selectedEpisodeID = episode.id
        currentEpisodeLabel = episode.displayTitle
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
    
    private func loadEpisodes(for anime: AnimeSearchResult, autoloadDanmaku: Bool) async throws {
        let loadedEpisodes = try await dandanplayClient.loadEpisodes(for: anime.id)
        episodes = loadedEpisodes
        
        guard autoloadDanmaku else { return }
        
        let matchingEpisode = loadedEpisodes.first(where: { $0.number == inferredEpisodeNumber }) ?? loadedEpisodes.first
        if let matchingEpisode {
            selectedEpisodeID = matchingEpisode.id
            currentEpisodeLabel = matchingEpisode.displayTitle
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
        
        // ffmpeg/video decoder diagnostics are noisy and often recoverable; they
        // should stay in the debug log instead of interrupting playback with an alert.
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
        systemMediaController.update(
            metadata: .init(
                title: title,
                albumTitle: selectedAnime?.title,
                assetURL: currentVideoURL
            ),
            snapshot: playback,
            active: currentVideoURL != nil
        )
    }
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
    
    private struct CommandRegistration {
        let command: MPRemoteCommand
        let token: Any
    }
    
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var commandRegistrations: [CommandRegistration] = []
    private var active = false
    private var latestSnapshot = PlaybackSnapshot()
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
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
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
    
    func update(metadata: Metadata, snapshot: PlaybackSnapshot, active: Bool) {
        let activeChanged = self.active != active
        self.active = active
        latestSnapshot = snapshot
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
