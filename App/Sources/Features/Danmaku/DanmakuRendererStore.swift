import CoreGraphics
import CoreText
import Foundation

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

@MainActor
final class DanmakuRendererStore {
    private(set) var activeItems: [ActiveDanmaku] = []

    private(set) var configuration: DanmakuRenderConfiguration
    private(set) var contentVersion: UInt64 = 0
    private(set) var lastViewportSize: CGSize = .zero
    private(set) var lastMetrics: DanmakuLayoutMetrics = .playbackChrome

    private var comments: [DanmakuComment] = []
    private var nextIndex = 0
    private var lastPlaybackTime = -1.0
    private var scrollLanes: [Double] = []
    private var topLanes: [Double] = []
    private var bottomLanes: [Double] = []
    private var lastLayoutSignature: DanmakuLayoutSignature?

    init(configuration: DanmakuRenderConfiguration = .default) {
        self.configuration = configuration.clamped()
    }

    var loadedComments: [DanmakuComment] {
        comments
    }

    func load(_ comments: [DanmakuComment]) {
        self.comments = comments.sorted(by: { $0.time < $1.time })
        activeItems = []
        nextIndex = 0
        lastPlaybackTime = -1.0
        scrollLanes = []
        topLanes = []
        bottomLanes = []
        lastLayoutSignature = nil
        lastViewportSize = .zero
        lastMetrics = .playbackChrome
        bumpContentVersion()
    }

    func clear() {
        load([])
    }

    func updateConfiguration(_ configuration: DanmakuRenderConfiguration) {
        let clampedConfiguration = configuration.clamped()
        guard clampedConfiguration != self.configuration else { return }

        self.configuration = clampedConfiguration
        lastLayoutSignature = nil
        if lastPlaybackTime >= 0 {
            reset(to: lastPlaybackTime)
        } else if !activeItems.isEmpty {
            activeItems = []
        }
        bumpContentVersion()
    }

    @discardableResult
    func sync(
        playbackTime: Double,
        viewportSize: CGSize,
        metrics: DanmakuLayoutMetrics = .playbackChrome
    ) -> Bool {
        guard !comments.isEmpty, viewportSize.width > 0, viewportSize.height > 0
        else {
            if !activeItems.isEmpty {
                activeItems = []
                bumpContentVersion()
            }
            return false
        }

        lastViewportSize = viewportSize
        lastMetrics = metrics

        let lanePlan = resolvedLanePlan(
            for: viewportSize,
            metrics: metrics
        )
        var didChange = false
        if shouldReset(
            for: playbackTime,
            layoutSignature: DanmakuLayoutSignature(
                viewportSize: viewportSize,
                metrics: metrics,
                lanePlan: lanePlan,
                configuration: configuration
            )
        ) {
            reset(to: playbackTime)
            didChange = true
        }

        configureLanes(using: lanePlan)
        let previousCount = activeItems.count
        activeItems.removeAll(where: { $0.endTime <= playbackTime })
        didChange = didChange || activeItems.count != previousCount

        while nextIndex < comments.count,
            comments[nextIndex].time <= playbackTime
        {
            spawn(
                comments[nextIndex],
                playbackTime: playbackTime,
                viewportSize: viewportSize,
                lanePlan: lanePlan
            )
            nextIndex += 1
            didChange = true
        }

        lastPlaybackTime = playbackTime
        if didChange {
            bumpContentVersion()
        }
        return didChange
    }

    func point(
        for item: ActiveDanmaku,
        playbackTime: Double,
        viewportSize: CGSize,
        metrics: DanmakuLayoutMetrics = .playbackChrome
    ) -> CGPoint {
        switch item.region {
        case .scroll:
            let progress = max(
                0,
                min(1, (playbackTime - item.startTime) / item.duration)
            )
            let minX = metrics.horizontalInset - item.widthEstimate / 2
            let maxX =
                viewportSize.width - metrics.horizontalInset + item
                .widthEstimate / 2
            let x = maxX - (maxX - minX) * progress
            return CGPoint(
                x: x,
                y: yPosition(
                    for: item,
                    viewportSize: viewportSize,
                    metrics: metrics
                )
            )
        case .top, .bottom:
            return CGPoint(
                x: viewportSize.width / 2,
                y: yPosition(
                    for: item,
                    viewportSize: viewportSize,
                    metrics: metrics
                )
            )
        }
    }

    private func shouldReset(
        for playbackTime: Double,
        layoutSignature: DanmakuLayoutSignature
    ) -> Bool {
        if lastLayoutSignature != layoutSignature {
            lastLayoutSignature = layoutSignature
            return true
        }
        guard lastPlaybackTime >= 0 else { return true }
        if playbackTime < lastPlaybackTime - 0.2 {
            return true
        }
        return abs(playbackTime - lastPlaybackTime) > 8
    }

    private func reset(to playbackTime: Double) {
        activeItems = []
        // Back up a small window so newly visible comments are respawned after a seek or
        // when the renderer first syncs to a non-zero playback time.
        nextIndex = comments.partitioningIndex(where: {
            $0.time >= max(0, playbackTime - 12)
        })
        lastPlaybackTime = playbackTime
        scrollLanes = scrollLanes.map { _ in playbackTime }
        topLanes = topLanes.map { _ in playbackTime }
        bottomLanes = bottomLanes.map { _ in playbackTime }
    }

    private func configureLanes(using lanePlan: DanmakuLanePlan) {
        if scrollLanes.count != lanePlan.scrollCount {
            scrollLanes = Array(
                repeating: lastPlaybackTime,
                count: lanePlan.scrollCount
            )
        }
        if topLanes.count != lanePlan.topCount {
            topLanes = Array(
                repeating: lastPlaybackTime,
                count: lanePlan.topCount
            )
        }
        if bottomLanes.count != lanePlan.bottomCount {
            bottomLanes = Array(
                repeating: lastPlaybackTime,
                count: lanePlan.bottomCount
            )
        }
    }

    private func spawn(
        _ comment: DanmakuComment,
        playbackTime: Double,
        viewportSize: CGSize,
        lanePlan: DanmakuLanePlan
    ) {
        let fontSize = lanePlan.fontSize
        let renderWidth = resolvedRenderWidth(
            for: comment.text,
            fontSize: fontSize
        )
        let widthEstimate = resolvedCollisionWidth(
            for: comment.text,
            fontSize: fontSize,
            renderWidth: renderWidth
        )

        switch comment.presentation {
        case .scroll:
            let duration = max(
                7.2,
                min(11.5, 7.2 + Double(widthEstimate / 220))
            )
            let reservation = bestScrollLane(
                widthEstimate: widthEstimate,
                duration: duration,
                playbackTime: playbackTime,
                viewportSize: viewportSize
            )
            let startTime = reservation.availableTime
            activeItems.append(
                ActiveDanmaku(
                    comment: comment,
                    lane: reservation.lane,
                    region: .scroll,
                    startTime: startTime,
                    endTime: startTime + duration,
                    duration: duration,
                    widthEstimate: widthEstimate,
                    renderWidth: renderWidth,
                    fontSize: fontSize
                )
            )
        case .top:
            let duration = 4.2
            let lane = bestLane(in: topLanes, at: playbackTime)
            topLanes[lane] = playbackTime + duration
            activeItems.append(
                ActiveDanmaku(
                    comment: comment,
                    lane: lane,
                    region: .top,
                    startTime: playbackTime,
                    endTime: playbackTime + duration,
                    duration: duration,
                    widthEstimate: widthEstimate,
                    renderWidth: renderWidth,
                    fontSize: fontSize
                )
            )
        case .bottom:
            let duration = 4.2
            let lane = bestLane(in: bottomLanes, at: playbackTime)
            bottomLanes[lane] = playbackTime + duration
            activeItems.append(
                ActiveDanmaku(
                    comment: comment,
                    lane: lane,
                    region: .bottom,
                    startTime: playbackTime,
                    endTime: playbackTime + duration,
                    duration: duration,
                    widthEstimate: widthEstimate,
                    renderWidth: renderWidth,
                    fontSize: fontSize
                )
            )
        }
    }

    private func bestLane(in lanes: [Double], at playbackTime: Double) -> Int {
        if let freeLane = lanes.firstIndex(where: { $0 <= playbackTime }) {
            return freeLane
        }
        return lanes.enumerated().min(by: { $0.element < $1.element })?.offset
            ?? 0
    }

    private func bestScrollLane(
        widthEstimate: CGFloat,
        duration: Double,
        playbackTime: Double,
        viewportSize: CGSize
    ) -> (lane: Int, availableTime: Double) {
        guard !scrollLanes.isEmpty else {
            return (0, playbackTime)
        }

        return scrollLanes.indices
            .map { lane in
                (
                    lane: lane,
                    availableTime: laneAvailabilityTime(
                        lane: lane,
                        candidateWidthEstimate: widthEstimate,
                        candidateDuration: duration,
                        playbackTime: playbackTime,
                        viewportSize: viewportSize
                    )
                )
            }
            .min { lhs, rhs in
                if lhs.availableTime == rhs.availableTime {
                    return lhs.lane < rhs.lane
                }
                return lhs.availableTime < rhs.availableTime
            } ?? (0, playbackTime)
    }

    private func laneAvailabilityTime(
        lane: Int,
        candidateWidthEstimate: CGFloat,
        candidateDuration: Double,
        playbackTime: Double,
        viewportSize: CGSize,
        metrics: DanmakuLayoutMetrics = .playbackChrome
    ) -> Double {
        guard let blocker = latestScrollItem(in: lane) else {
            return playbackTime
        }

        let referenceTime = max(playbackTime, blocker.startTime)
        let blockerRemaining = max(0, blocker.endTime - referenceTime)
        guard blockerRemaining > 0 else {
            return playbackTime
        }

        let blockerSpeed = scrollSpeed(
            widthEstimate: blocker.widthEstimate,
            duration: blocker.duration,
            viewportWidth: viewportSize.width,
            metrics: metrics
        )
        let candidateSpeed = scrollSpeed(
            widthEstimate: candidateWidthEstimate,
            duration: candidateDuration,
            viewportWidth: viewportSize.width,
            metrics: metrics
        )

        let viewportRight = viewportSize.width - metrics.horizontalInset
        let blockerRightEdge: CGFloat
        if referenceTime <= blocker.startTime {
            blockerRightEdge = viewportRight + blocker.widthEstimate
        } else {
            let blockerPoint = point(
                for: blocker,
                playbackTime: referenceTime,
                viewportSize: viewportSize,
                metrics: metrics
            )
            blockerRightEdge = blockerPoint.x + blocker.widthEstimate / 2
        }

        let gap = viewportRight - blockerRightEdge
        let minimumGap = max(18, blocker.fontSize * 0.7)

        let extraWait: Double
        if candidateSpeed > blockerSpeed {
            let delta = candidateSpeed - blockerSpeed
            extraWait = max(
                0,
                (Double(minimumGap) + delta * blockerRemaining - Double(gap))
                    / candidateSpeed
            )
        } else {
            extraWait = max(
                0,
                (Double(minimumGap) - Double(gap)) / max(blockerSpeed, 1)
            )
        }

        return referenceTime + extraWait
    }

    private func latestScrollItem(in lane: Int) -> ActiveDanmaku? {
        activeItems
            .filter { $0.region == .scroll && $0.lane == lane }
            .max { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.startTime < rhs.startTime
            }
    }

    private func yPosition(
        for item: ActiveDanmaku,
        viewportSize: CGSize,
        metrics: DanmakuLayoutMetrics
    ) -> CGFloat {
        let laneHeight = laneHeight(for: item.fontSize)
        let displayAreaHeight = resolvedDisplayAreaHeight(
            for: viewportSize,
            metrics: metrics,
            fontSize: item.fontSize
        )
        switch item.region {
        case .scroll:
            return metrics.topInset + laneHeight * CGFloat(item.lane + 1)
        case .top:
            return metrics.topInset + laneHeight * CGFloat(item.lane + 1)
        case .bottom:
            return metrics.topInset + displayAreaHeight - laneHeight
                * CGFloat(item.lane + 1)
        }
    }

    private func resolvedFontSize(for viewportSize: CGSize) -> CGFloat {
        let _ = viewportSize
        return configuration.resolvedFontSize
    }

    private func laneHeight(for fontSize: CGFloat) -> CGFloat {
        fontSize * 1.24
    }

    private func resolvedRenderWidth(for text: String, fontSize: CGFloat)
        -> CGFloat
    {
        max(
            48,
            renderedTextWidth(
                text,
                fontSize: fontSize,
                fontStyle: configuration.fontStyle
            )
        )
    }

    private func resolvedCollisionWidth(
        for text: String,
        fontSize: CGFloat,
        renderWidth: CGFloat
    ) -> CGFloat {
        max(
            renderWidth,
            max(
                72,
                measuredTextWidth(
                    text,
                    fontSize: fontSize,
                    fontStyle: configuration.fontStyle
                ) + fontSize * 0.9
            )
        )
    }

    private func scrollSpeed(
        widthEstimate: CGFloat,
        duration: Double,
        viewportWidth: CGFloat,
        metrics: DanmakuLayoutMetrics
    ) -> Double {
        Double(
            scrollTravelDistance(
                widthEstimate: widthEstimate,
                viewportWidth: viewportWidth,
                metrics: metrics
            )
        ) / duration
    }

    private func scrollTravelDistance(
        widthEstimate: CGFloat,
        viewportWidth: CGFloat,
        metrics: DanmakuLayoutMetrics
    ) -> CGFloat {
        viewportWidth - metrics.horizontalInset * 2 + widthEstimate
    }

    private func resolvedLanePlan(
        for viewportSize: CGSize,
        metrics: DanmakuLayoutMetrics
    ) -> DanmakuLanePlan {
        let fontSize = resolvedFontSize(for: viewportSize)
        let laneHeight = laneHeight(for: fontSize)
        let displayAreaHeight = resolvedDisplayAreaHeight(
            for: viewportSize,
            metrics: metrics,
            fontSize: fontSize
        )
        let edgeAreaHeight = max(
            laneHeight * 2,
            min(displayAreaHeight * 0.18, laneHeight * 3)
        )
        let scrollAreaHeight = max(
            laneHeight * 3,
            displayAreaHeight - edgeAreaHeight * 2
        )

        return DanmakuLanePlan(
            fontSize: fontSize,
            laneHeight: laneHeight,
            displayAreaHeight: displayAreaHeight,
            scrollCount: max(5, Int(scrollAreaHeight / laneHeight)),
            topCount: max(2, Int(edgeAreaHeight / laneHeight)),
            bottomCount: max(2, Int(edgeAreaHeight / laneHeight))
        )
    }

    private func resolvedDisplayAreaHeight(
        for viewportSize: CGSize,
        metrics: DanmakuLayoutMetrics,
        fontSize: CGFloat
    ) -> CGFloat {
        let usableHeight = max(
            laneHeight(for: fontSize) * 4,
            viewportSize.height - metrics.topInset - metrics.bottomInset
        )
        return min(
            usableHeight,
            max(
                laneHeight(for: fontSize) * 4,
                usableHeight * configuration.displayArea.coverageRatio
            )
        )
    }

    private func bumpContentVersion() {
        contentVersion &+= 1
    }
}

private struct DanmakuLanePlan: Equatable {
    let fontSize: CGFloat
    let laneHeight: CGFloat
    let displayAreaHeight: CGFloat
    let scrollCount: Int
    let topCount: Int
    let bottomCount: Int
}

private struct DanmakuLayoutSignature: Equatable {
    let viewportWidth: Int
    let viewportHeight: Int
    let topInset: Int
    let bottomInset: Int
    let horizontalInset: Int
    let fontStyle: DanmakuFontStyle
    let fontSize: Int
    let displayArea: DanmakuDisplayArea
    let scrollCount: Int
    let topCount: Int
    let bottomCount: Int

    init(
        viewportSize: CGSize,
        metrics: DanmakuLayoutMetrics,
        lanePlan: DanmakuLanePlan,
        configuration: DanmakuRenderConfiguration
    ) {
        viewportWidth = Int((viewportSize.width * 2).rounded())
        viewportHeight = Int((viewportSize.height * 2).rounded())
        topInset = Int((metrics.topInset * 2).rounded())
        bottomInset = Int((metrics.bottomInset * 2).rounded())
        horizontalInset = Int((metrics.horizontalInset * 2).rounded())
        fontStyle = configuration.fontStyle
        fontSize = Int((lanePlan.fontSize * 4).rounded())
        displayArea = configuration.displayArea
        scrollCount = lanePlan.scrollCount
        topCount = lanePlan.topCount
        bottomCount = lanePlan.bottomCount
    }
}

extension Array {
    fileprivate func partitioningIndex(where predicate: (Element) -> Bool)
        -> Int
    {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}

private func measuredTextWidth(
    _ text: String,
    fontSize: CGFloat,
    fontStyle: DanmakuFontStyle
) -> CGFloat {
    #if canImport(AppKit)
        let font = fontStyle.platformFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    #elseif canImport(UIKit)
        let font = fontStyle.platformFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    #else
        return ceil(CGFloat(text.count) * fontSize * 0.68)
    #endif
}

private func renderedTextWidth(
    _ text: String,
    fontSize: CGFloat,
    fontStyle: DanmakuFontStyle
) -> CGFloat {
    let font = fontStyle.ctFont(ofSize: fontSize)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font
            ]
        )
    )
    let bounds = CTLineGetBoundsWithOptions(
        line,
        [.useGlyphPathBounds, .excludeTypographicLeading]
    )
    if bounds.isNull || !bounds.width.isFinite || bounds.width <= 0 {
        return measuredTextWidth(
            text,
            fontSize: fontSize,
            fontStyle: fontStyle
        )
    }
    return ceil(bounds.width)
}
