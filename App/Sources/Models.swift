import Foundation
import SwiftUI

struct AnimeSearchResult: Identifiable, Hashable {
    let id: Int
    let title: String
    let typeDescription: String
    let imageURL: URL?
    let episodeCount: Int?
}

struct AnimeEpisode: Identifiable, Hashable {
    let id: Int
    let number: Int?
    let title: String
    
    var displayTitle: String {
        if let number, !title.contains("\(number)") {
            return "第 \(number) 话 · \(title)"
        }
        return title
    }
}

enum DanmakuPresentation: String, Hashable {
    case scroll
    case top
    case bottom
}

struct DanmakuColor: Hashable {
    let red: Double
    let green: Double
    let blue: Double
    
    var swiftUI: Color {
        Color(red: red, green: green, blue: blue)
    }
    
    static let white = DanmakuColor(red: 1, green: 1, blue: 1)
    
    static func from(decimalColor: Int) -> DanmakuColor {
        let red = Double((decimalColor >> 16) & 0xFF) / 255.0
        let green = Double((decimalColor >> 8) & 0xFF) / 255.0
        let blue = Double(decimalColor & 0xFF) / 255.0
        return DanmakuColor(red: red, green: green, blue: blue)
    }
}

struct DanmakuComment: Identifiable, Hashable {
    let id = UUID()
    let time: Double
    let text: String
    let presentation: DanmakuPresentation
    let color: DanmakuColor
}

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

struct AppErrorState: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

enum DanmakuRegion: Hashable {
    case scroll
    case top
    case bottom
}

struct ActiveDanmaku: Identifiable, Hashable {
    let id = UUID()
    let comment: DanmakuComment
    let lane: Int
    let region: DanmakuRegion
    let startTime: Double
    let endTime: Double
    let duration: Double
    let widthEstimate: CGFloat
    let fontSize: CGFloat
}

struct DanmakuLayoutMetrics: Hashable {
    let topInset: CGFloat
    let bottomInset: CGFloat
    let horizontalInset: CGFloat
    
    static let playbackChrome = DanmakuLayoutMetrics(topInset: 26, bottomInset: 118, horizontalInset: 18)
}
