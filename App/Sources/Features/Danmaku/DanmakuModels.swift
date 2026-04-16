import CoreText
import SwiftUI

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

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

    func metalRGBA(opacity: Double) -> SIMD4<Float> {
        SIMD4(
            Float(red),
            Float(green),
            Float(blue),
            Float(min(max(opacity, 0), 1))
        )
    }
}

enum DanmakuFontStyle: String, Codable, CaseIterable, Hashable, Identifiable {
    case systemRounded
    case systemSans
    case systemSerif
    case systemMonospaced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemRounded:
            "圆体"
        case .systemSans:
            "无衬线"
        case .systemSerif:
            "衬线"
        case .systemMonospaced:
            "等宽"
        }
    }

    var swiftUIFontDesign: Font.Design {
        switch self {
        case .systemRounded:
            .rounded
        case .systemSans:
            .default
        case .systemSerif:
            .serif
        case .systemMonospaced:
            .monospaced
        }
    }

    func platformFont(ofSize size: CGFloat) -> PlatformFont {
        #if canImport(AppKit)
            let base = NSFont.systemFont(ofSize: size, weight: .heavy)
            let descriptor = fontDescriptor(from: base.fontDescriptor)
            return NSFont(descriptor: descriptor, size: size) ?? base
        #elseif canImport(UIKit)
            let base = UIFont.systemFont(ofSize: size, weight: .heavy)
            let descriptor = fontDescriptor(from: base.fontDescriptor)
            return UIFont(descriptor: descriptor, size: size)
        #else
            fatalError("Unsupported platform font backend.")
        #endif
    }

    func ctFont(ofSize size: CGFloat) -> CTFont {
        platformFont(ofSize: size) as CTFont
    }

    #if canImport(AppKit)
        private func fontDescriptor(from descriptor: NSFontDescriptor)
            -> NSFontDescriptor
        {
            switch self {
            case .systemRounded:
                descriptor.withDesign(.rounded) ?? descriptor
            case .systemSans:
                descriptor
            case .systemSerif:
                descriptor.withDesign(.serif) ?? descriptor
            case .systemMonospaced:
                descriptor.withDesign(.monospaced) ?? descriptor
            }
        }
    #elseif canImport(UIKit)
        private func fontDescriptor(from descriptor: UIFontDescriptor)
            -> UIFontDescriptor
        {
            switch self {
            case .systemRounded:
                descriptor.withDesign(.rounded) ?? descriptor
            case .systemSans:
                descriptor
            case .systemSerif:
                descriptor.withDesign(.serif) ?? descriptor
            case .systemMonospaced:
                descriptor.withDesign(.monospaced) ?? descriptor
            }
        }
    #endif
}

enum DanmakuDisplayArea: String, Codable, CaseIterable, Hashable, Identifiable {
    case quarter
    case half
    case threeQuarters
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quarter:
            "1/4 屏"
        case .half:
            "1/2 屏"
        case .threeQuarters:
            "3/4 屏"
        case .full:
            "全屏"
        }
    }

    var coverageRatio: CGFloat {
        switch self {
        case .quarter:
            0.25
        case .half:
            0.5
        case .threeQuarters:
            0.75
        case .full:
            1
        }
    }
}

struct DanmakuRenderConfiguration: Codable, Hashable {
    var fontStyle: DanmakuFontStyle
    var fontSize: Double
    var displayArea: DanmakuDisplayArea
    var opacity: Double

    static let `default` = DanmakuRenderConfiguration(
        fontStyle: .systemRounded,
        fontSize: 24,
        displayArea: .threeQuarters,
        opacity: 0.66
    )

    init(
        fontStyle: DanmakuFontStyle,
        fontSize: Double,
        displayArea: DanmakuDisplayArea,
        opacity: Double = 0.66
    ) {
        self.fontStyle = fontStyle
        self.fontSize = fontSize
        self.displayArea = displayArea
        self.opacity = opacity
    }

    var resolvedFontSize: CGFloat {
        CGFloat(fontSize)
    }

    func clamped() -> DanmakuRenderConfiguration {
        var copy = self
        copy.fontSize = min(max(fontSize, 14), 52)
        copy.opacity = min(max(opacity, 0), 1)
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case fontStyle
        case fontSize
        case displayArea
        case opacity
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontStyle = try container.decode(
            DanmakuFontStyle.self,
            forKey: .fontStyle
        )
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        displayArea = try container.decode(
            DanmakuDisplayArea.self,
            forKey: .displayArea
        )
        opacity =
            try container.decodeIfPresent(Double.self, forKey: .opacity)
            ?? 0.66
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fontStyle, forKey: .fontStyle)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(displayArea, forKey: .displayArea)
        try container.encode(opacity, forKey: .opacity)
    }
}

struct DanmakuComment: Identifiable, Hashable {
    let id = UUID()
    let time: Double
    let text: String
    let presentation: DanmakuPresentation
    let color: DanmakuColor
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
    let renderWidth: CGFloat
    let fontSize: CGFloat
}

struct DanmakuLayoutMetrics: Hashable {
    let topInset: CGFloat
    let bottomInset: CGFloat
    let horizontalInset: CGFloat

    static let playbackChrome = DanmakuLayoutMetrics(
        topInset: 26,
        bottomInset: 118,
        horizontalInset: 18
    )

    static let immersivePlayback = DanmakuLayoutMetrics(
        topInset: 26,
        bottomInset: 118,
        horizontalInset: 0
    )
}

#if canImport(AppKit)
    typealias PlatformFont = NSFont
#elseif canImport(UIKit)
    typealias PlatformFont = UIFont
#endif
