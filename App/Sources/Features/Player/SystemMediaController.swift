import Foundation
import MediaPlayer

#if os(iOS)
    import AVFoundation
#endif

final class SystemMediaController {
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
        guard
            activeChanged
                || shouldPublishNowPlayingInfo(
                    metadata: metadata,
                    snapshot: snapshot
                )
        else {
            return
        }
        publishNowPlayingInfo(metadata: metadata, snapshot: snapshot)
    }

    private func configureRemoteCommands() {
        register(commandCenter.playCommand) { [weak self] _ in
            guard let self, self.active else {
                return .noActionableNowPlayingItem
            }
            self.invokeOnMain { $0.onPlay?() }
            return .success
        }
        register(commandCenter.pauseCommand) { [weak self] _ in
            guard let self, self.active else {
                return .noActionableNowPlayingItem
            }
            self.invokeOnMain { $0.onPause?() }
            return .success
        }
        register(commandCenter.togglePlayPauseCommand) { [weak self] _ in
            guard let self, self.active else {
                return .noActionableNowPlayingItem
            }
            self.invokeOnMain { $0.onTogglePlayPause?() }
            return .success
        }
        register(commandCenter.changePlaybackPositionCommand) {
            [weak self] event in
            guard let self, self.active else {
                return .noActionableNowPlayingItem
            }
            guard let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self.invokeOnMain { $0.onSeek?(event.positionTime) }
            return .success
        }
        register(commandCenter.skipForwardCommand) { [weak self] event in
            guard let self, self.active else {
                return .noActionableNowPlayingItem
            }
            let interval =
                (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self.invokeOnMain { $0.onSkipForward?(interval) }
            return .success
        }
        register(commandCenter.skipBackwardCommand) { [weak self] event in
            guard let self, self.active else {
                return .noActionableNowPlayingItem
            }
            let interval =
                (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self.invokeOnMain { $0.onSkipBackward?(interval) }
            return .success
        }
        register(commandCenter.nextTrackCommand) { [weak self] _ in
            guard let self, self.active, self.canGoToNextTrack else {
                return .noActionableNowPlayingItem
            }
            self.invokeOnMain { $0.onNextTrack?() }
            return .success
        }
        register(commandCenter.previousTrackCommand) { [weak self] _ in
            guard let self, self.active, self.canGoToPreviousTrack else {
                return .noActionableNowPlayingItem
            }
            self.invokeOnMain { $0.onPreviousTrack?() }
            return .success
        }
    }

    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) ->
            MPRemoteCommandHandlerStatus
    ) {
        let token = command.addTarget(handler: handler)
        commandRegistrations.append(
            CommandRegistration(command: command, token: token)
        )
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
        commandCenter.previousTrackCommand.isEnabled =
            active && canGoToPreviousTrack
    }

    private func shouldPublishNowPlayingInfo(
        metadata: Metadata,
        snapshot: PlaybackSnapshot
    ) -> Bool {
        guard let lastPublishedMetadata else { return true }
        if metadata != lastPublishedMetadata {
            return true
        }
        if snapshot.loaded != lastPublishedSnapshot.loaded
            || snapshot.paused != lastPublishedSnapshot.paused
        {
            return true
        }
        if abs(snapshot.duration - lastPublishedSnapshot.duration) >= 0.5 {
            return true
        }

        let positionDelta = abs(
            snapshot.position - lastPublishedSnapshot.position
        )
        let positionThreshold = snapshot.paused ? 0.25 : 2.0
        return positionDelta >= positionThreshold
    }

    private func publishNowPlayingInfo(
        metadata: Metadata,
        snapshot: PlaybackSnapshot
    ) {
        var nowPlayingInfo = infoCenter.nowPlayingInfo ?? [:]
        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata.title
        setOptionalValue(
            metadata.albumTitle,
            for: MPMediaItemPropertyAlbumTitle,
            in: &nowPlayingInfo
        )
        setOptionalValue(
            metadata.assetURL,
            for: MPNowPlayingInfoPropertyAssetURL,
            in: &nowPlayingInfo
        )
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] =
            MPNowPlayingInfoMediaType.video.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
            snapshot.position
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] =
            snapshot.loaded && !snapshot.paused ? 1.0 : 0.0

        if snapshot.duration > 0 {
            let progress = min(max(snapshot.position / snapshot.duration, 0), 1)
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackProgress] = progress
        } else {
            nowPlayingInfo.removeValue(
                forKey: MPNowPlayingInfoPropertyPlaybackProgress
            )
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

    private func invokeOnMain(
        _ work: @escaping @MainActor (SystemMediaController) -> Void
    ) {
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
                        try session.setCategory(
                            .playback,
                            mode: .moviePlayback,
                            options: []
                        )
                        audioSessionConfigured = true
                    } catch {
                        #if DEBUG
                            print(
                                "[media] failed to set audio session category: \(error)"
                            )
                        #endif
                    }
                }

                guard !audioSessionActive else { return }
                do {
                    try session.setActive(true)
                    audioSessionActive = true
                } catch {
                    #if DEBUG
                        print(
                            "[media] failed to activate audio session: \(error)"
                        )
                    #endif
                }
            } else if audioSessionActive {
                do {
                    try session.setActive(
                        false,
                        options: [.notifyOthersOnDeactivation]
                    )
                } catch {
                    #if DEBUG
                        print(
                            "[media] failed to deactivate audio session: \(error)"
                        )
                    #endif
                }
                audioSessionActive = false
            }
        }
    #else
        private func updateAudioSession(active _: Bool) {}
    #endif
}
