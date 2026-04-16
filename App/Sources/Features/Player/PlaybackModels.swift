import Foundation

enum MediaTrackKind: String, Hashable {
    case audio
    case subtitle
}

struct MediaTrackOption: Identifiable, Hashable {
    let kind: MediaTrackKind
    let mpvID: Int64
    let title: String
    let detail: String
    let isExternal: Bool

    var id: String {
        "\(kind.rawValue)-\(mpvID)"
    }
}

struct PlayerTrackState: Equatable {
    var audioTracks: [MediaTrackOption] = []
    var subtitleTracks: [MediaTrackOption] = []
    var selectedAudioID: Int64?
    var selectedSubtitleID: Int64?
}

struct PlaybackSnapshot: Equatable {
    var position: Double = 0
    var duration: Double = 0
    var paused: Bool = true
    var loaded: Bool = false
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

struct PlaybackTimebase: Equatable {
    var position: Double = 0
    var duration: Double = 0
    var paused: Bool = true
    var loaded: Bool = false
    var updatedAt: Date = .distantPast

    init(
        position: Double = 0,
        duration: Double = 0,
        paused: Bool = true,
        loaded: Bool = false,
        updatedAt: Date = .distantPast
    ) {
        self.position = position
        self.duration = duration
        self.paused = paused
        self.loaded = loaded
        self.updatedAt = updatedAt
    }

    init(snapshot: PlaybackSnapshot, updatedAt: Date) {
        self.init(
            position: snapshot.position,
            duration: snapshot.duration,
            paused: snapshot.paused,
            loaded: snapshot.loaded,
            updatedAt: updatedAt
        )
    }

    func resolvedPosition(at date: Date) -> Double {
        guard loaded else { return 0 }
        guard !paused else { return bounded(position) }

        let elapsed = max(0, date.timeIntervalSince(updatedAt))
        return bounded(position + elapsed)
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
