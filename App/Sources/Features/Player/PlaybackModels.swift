import Foundation

enum MediaTrackKind: String, Hashable {
    case audio
    case subtitle
}

enum SpatialAudioDecoder: String, Hashable {
    case eac3joc
    case truehdatmos

    var mpvDecoderName: String { rawValue }

    var sourceLabel: String {
        switch self {
        case .eac3joc:
            return "E-AC-3 JOC"
        case .truehdatmos:
            return "TrueHD Atmos"
        }
    }

    var menuDetail: String {
        "\(sourceLabel) -> \(mpvDecoderName) + coreaudio_spatial714"
    }
}

struct MediaTrackOption: Identifiable, Hashable {
    let kind: MediaTrackKind
    let mpvID: Int64
    let title: String
    let detail: String
    let isExternal: Bool
    let codec: String?
    let codecDescription: String?
    let codecProfile: String?

    var id: String {
        "\(kind.rawValue)-\(mpvID)"
    }

    var spatialAudioDecoder: SpatialAudioDecoder? {
        let candidates = [codec, codecDescription, codecProfile, title, detail]

        if Self.containsEAC3JOCMarker(in: candidates) {
            return .eac3joc
        }

        if Self.containsTrueHDAtmosMarker(in: candidates) {
            return .truehdatmos
        }

        return nil
    }

    var supportsSpatialAudio: Bool {
        spatialAudioDecoder != nil
    }

    private static func normalizedMarkerValue(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }

        let normalized = value.lowercased().filter { character in
            character.isLetter || character.isNumber
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func combinedMarkerValue(_ values: [String?]) -> String? {
        let combined = values.compactMap(normalizedMarkerValue).joined()
        return combined.isEmpty ? nil : combined
    }

    private static func containsEAC3JOCMarker(in values: [String?]) -> Bool {
        guard let normalized = combinedMarkerValue(values) else { return false }

        if normalized.contains("eac3joc") || normalized.contains("ec3joc") {
            return true
        }

        let isEAC3Family =
            normalized.contains("eac3")
            || normalized.contains("ec3")
            || normalized.contains("ddp")
            || normalized.contains("dolbydigitalplus")
            || normalized.contains("digitalplus")

        guard isEAC3Family else { return false }
        return normalized.contains("joc") || normalized.contains("atmos")
    }

    private static func containsTrueHDAtmosMarker(in values: [String?]) -> Bool {
        guard let normalized = combinedMarkerValue(values) else { return false }

        if normalized.contains("truehdatmos")
            || normalized.contains("dolbytruehdatmos")
        {
            return true
        }

        let isTrueHDFamily =
            normalized.contains("truehd")
            || normalized.contains("dolbytruehd")
            || normalized.contains("mlp")

        guard isTrueHDFamily else { return false }
        return normalized.contains("atmos")
    }
}

struct PlayerTrackState: Equatable {
    var audioTracks: [MediaTrackOption] = []
    var subtitleTracks: [MediaTrackOption] = []
    var selectedAudioID: Int64?
    var selectedSubtitleID: Int64?
}

struct PlaybackPreferences: Codable, Equatable {
    static let `default` = PlaybackPreferences()
    static let playbackRatePresets: [Double] = [
        0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0,
    ]
    static let seekIntervalPresets: [Double] = [
        5, 10, 15, 30, 60,
    ]

    var playbackRate: Double = 1.0
    var seekInterval: Double = 10.0

    func clamped() -> PlaybackPreferences {
        PlaybackPreferences(
            playbackRate: PlaybackPreferences.clampedPlaybackRate(playbackRate),
            seekInterval: PlaybackPreferences.clampedSeekInterval(seekInterval)
        )
    }

    static func clampedPlaybackRate(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(3.0, max(0.25, value))
    }

    static func clampedSeekInterval(_ value: Double) -> Double {
        guard value.isFinite else { return 10.0 }
        return min(600.0, max(1.0, value))
    }
}

struct PlaybackSnapshot: Equatable {
    var position: Double = 0
    var duration: Double = 0
    var paused: Bool = true
    var loaded: Bool = false
    var playbackRate: Double = 1.0
    var videoWidth: Int = 0
    var videoHeight: Int = 0

    var videoAspect: Double {
        guard videoWidth > 0, videoHeight > 0 else { return 0 }
        return Double(videoWidth) / Double(videoHeight)
    }

    var videoDisplaySize: CGSize {
        guard videoWidth > 0, videoHeight > 0 else { return .zero }
        return CGSize(width: videoWidth, height: videoHeight)
    }
}

enum PlaybackCaptureNaming {
    static func baseName(
        title: String,
        episodeLabel: String,
        collectionTitle: String?,
        assetURL: URL?
    ) -> String {
        let normalizedTitle =
            title.nilIfBlank.flatMap {
                assetURL?.isFileURL == true
                    ? URL(fileURLWithPath: $0).deletingPathExtension()
                        .lastPathComponent.nilIfBlank ?? $0
                    : $0
            }
            ?? assetURL.map {
                $0.isFileURL
                    ? $0.deletingPathExtension().lastPathComponent
                    : $0.lastPathComponent.nilIfBlank
                        .map {
                            URL(fileURLWithPath: $0).deletingPathExtension()
                                .lastPathComponent
                        }
                        ?? $0.absoluteString
            }
            ?? "Starmine"
        let normalizedCollection =
            collectionTitle?.nilIfBlank ?? normalizedTitle.nilIfBlank
        let normalizedEpisode = episodeLabel.nilIfBlank

        if let normalizedEpisode {
            let prefix = normalizedCollection ?? normalizedTitle
            return "\(prefix)-\(normalizedEpisode)"
        }

        if let normalizedCollection,
            normalizedCollection.caseInsensitiveCompare(normalizedTitle)
                != .orderedSame
        {
            return "\(normalizedCollection)-\(normalizedTitle)"
        }

        return normalizedCollection ?? normalizedTitle
    }

    static func timestamp(for positionSeconds: Double) -> String {
        let totalSeconds = max(0, Int(positionSeconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d-%02d-%02d", hours, minutes, seconds)
    }

    static func filename(
        title: String,
        episodeLabel: String,
        collectionTitle: String?,
        assetURL: URL?,
        positionSeconds: Double,
        fileExtension: String
    ) -> String {
        let base = baseName(
            title: title,
            episodeLabel: episodeLabel,
            collectionTitle: collectionTitle,
            assetURL: assetURL
        )
        .sanitizedFilenameComponent(fallback: "capture")
        let timestamp = timestamp(for: positionSeconds)
        let normalizedExtension =
            fileExtension.trimmingCharacters(
                in: CharacterSet(charactersIn: ".")
            )
            .lowercased()
            .nilIfBlank ?? "png"
        return "\(base)-\(timestamp).\(normalizedExtension)"
    }
}

struct PlaybackTimebase: Equatable {
    var position: Double = 0
    var duration: Double = 0
    var paused: Bool = true
    var loaded: Bool = false
    var playbackRate: Double = 1.0
    var updatedAt: Date = .distantPast

    init(
        position: Double = 0,
        duration: Double = 0,
        paused: Bool = true,
        loaded: Bool = false,
        playbackRate: Double = 1.0,
        updatedAt: Date = .distantPast
    ) {
        self.position = position
        self.duration = duration
        self.paused = paused
        self.loaded = loaded
        self.playbackRate = playbackRate
        self.updatedAt = updatedAt
    }

    init(snapshot: PlaybackSnapshot, updatedAt: Date) {
        self.init(
            position: snapshot.position,
            duration: snapshot.duration,
            paused: snapshot.paused,
            loaded: snapshot.loaded,
            playbackRate: snapshot.playbackRate,
            updatedAt: updatedAt
        )
    }

    func resolvedPosition(at date: Date) -> Double {
        guard loaded else { return 0 }
        guard !paused else { return bounded(position) }

        let elapsed = max(0, date.timeIntervalSince(updatedAt))
        return bounded(position + elapsed * playbackRate)
    }

    static func reconciled(
        from previous: PlaybackTimebase,
        previousSnapshot: PlaybackSnapshot,
        snapshot: PlaybackSnapshot,
        at date: Date,
        discontinuityThreshold: Double = 0.35
    ) -> PlaybackTimebase {
        guard previous.loaded, previousSnapshot.loaded, snapshot.loaded else {
            return PlaybackTimebase(snapshot: snapshot, updatedAt: date)
        }

        let currentPosition = previous.resolvedPosition(at: date)
        let rawDelta = snapshot.position - previousSnapshot.position
        let durationChanged =
            abs(snapshot.duration - previousSnapshot.duration) > 0.5
        let isDiscontinuous =
            durationChanged || abs(rawDelta) > discontinuityThreshold

        let resolvedPosition: Double
        if isDiscontinuous {
            resolvedPosition = snapshot.position
        } else {
            resolvedPosition = max(snapshot.position, currentPosition)
        }

        return PlaybackTimebase(
            position: bounded(resolvedPosition, duration: snapshot.duration),
            duration: snapshot.duration,
            paused: snapshot.paused,
            loaded: snapshot.loaded,
            playbackRate: snapshot.playbackRate,
            updatedAt: date
        )
    }

    private func bounded(_ value: Double) -> Double {
        Self.bounded(value, duration: duration)
    }

    private static func bounded(_ value: Double, duration: Double) -> Double {
        guard duration > 0 else { return max(0, value) }
        return min(duration, max(0, value))
    }
}
