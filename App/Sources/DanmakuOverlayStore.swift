import Foundation
import SwiftUI

@MainActor
final class DanmakuOverlayStore: ObservableObject {
    @Published private(set) var activeItems: [ActiveDanmaku] = []
    
    private var comments: [DanmakuComment] = []
    private var nextIndex = 0
    private var lastPlaybackTime = -1.0
    private var scrollLanes: [Double] = []
    private var topLanes: [Double] = []
    private var bottomLanes: [Double] = []
    
    func load(_ comments: [DanmakuComment]) {
        self.comments = comments.sorted(by: { $0.time < $1.time })
        activeItems = []
        nextIndex = 0
        lastPlaybackTime = -1.0
        scrollLanes = []
        topLanes = []
        bottomLanes = []
    }
    
    func clear() {
        load([])
    }
    
    func sync(playbackTime: Double, viewportSize: CGSize, metrics: DanmakuLayoutMetrics = .playbackChrome) {
        guard !comments.isEmpty, viewportSize.width > 0, viewportSize.height > 0 else {
            activeItems = []
            return
        }
        
        if shouldReset(for: playbackTime) {
            reset(to: playbackTime)
        }
        
        configureLanes(for: viewportSize, metrics: metrics)
        activeItems.removeAll(where: { $0.endTime <= playbackTime })
        
        while nextIndex < comments.count, comments[nextIndex].time <= playbackTime {
            spawn(comments[nextIndex], playbackTime: playbackTime, viewportSize: viewportSize)
            nextIndex += 1
        }
        
        lastPlaybackTime = playbackTime
    }
    
    func point(for item: ActiveDanmaku, playbackTime: Double, viewportSize: CGSize, metrics: DanmakuLayoutMetrics = .playbackChrome) -> CGPoint {
        switch item.region {
        case .scroll:
            let progress = max(0, min(1, (playbackTime - item.startTime) / item.duration))
            let minX = metrics.horizontalInset - item.widthEstimate / 2
            let maxX = viewportSize.width - metrics.horizontalInset + item.widthEstimate / 2
            let x = maxX - (maxX - minX) * progress
            return CGPoint(x: x, y: yPosition(for: item, viewportSize: viewportSize, metrics: metrics))
        case .top, .bottom:
            return CGPoint(x: viewportSize.width / 2, y: yPosition(for: item, viewportSize: viewportSize, metrics: metrics))
        }
    }
    
    private func shouldReset(for playbackTime: Double) -> Bool {
        guard lastPlaybackTime >= 0 else { return true }
        if playbackTime < lastPlaybackTime - 0.2 {
            return true
        }
        return abs(playbackTime - lastPlaybackTime) > 8
    }
    
    private func reset(to playbackTime: Double) {
        activeItems = []
        nextIndex = comments.partitioningIndex(where: { $0.time >= playbackTime })
        lastPlaybackTime = playbackTime
        scrollLanes = scrollLanes.map { _ in playbackTime }
        topLanes = topLanes.map { _ in playbackTime }
        bottomLanes = bottomLanes.map { _ in playbackTime }
    }
    
    private func configureLanes(for viewportSize: CGSize, metrics: DanmakuLayoutMetrics) {
        let fontSize = resolvedFontSize(for: viewportSize)
        let laneHeight = fontSize * 1.5
        let usableHeight = max(120, viewportSize.height - metrics.topInset - metrics.bottomInset)
        let scrollCount = max(4, Int((usableHeight * 0.64) / laneHeight))
        let topCount = max(2, Int((usableHeight * 0.16) / laneHeight))
        let bottomCount = max(2, Int((usableHeight * 0.16) / laneHeight))
        
        if scrollLanes.count != scrollCount {
            scrollLanes = Array(repeating: lastPlaybackTime, count: scrollCount)
        }
        if topLanes.count != topCount {
            topLanes = Array(repeating: lastPlaybackTime, count: topCount)
        }
        if bottomLanes.count != bottomCount {
            bottomLanes = Array(repeating: lastPlaybackTime, count: bottomCount)
        }
    }
    
    private func spawn(_ comment: DanmakuComment, playbackTime: Double, viewportSize: CGSize) {
        let fontSize = resolvedFontSize(for: viewportSize)
        let widthEstimate = max(72, CGFloat(comment.text.count) * fontSize * 0.62)
        
        switch comment.presentation {
        case .scroll:
            let duration = max(7.2, min(11.5, 7.2 + Double(widthEstimate / 220)))
            let lane = bestLane(in: scrollLanes, at: playbackTime)
            scrollLanes[lane] = playbackTime + duration * 0.38
            activeItems.append(
                ActiveDanmaku(
                    comment: comment,
                    lane: lane,
                    region: .scroll,
                    startTime: playbackTime,
                    endTime: playbackTime + duration,
                    duration: duration,
                    widthEstimate: widthEstimate,
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
                    fontSize: fontSize
                )
            )
        }
    }
    
    private func bestLane(in lanes: [Double], at playbackTime: Double) -> Int {
        if let freeLane = lanes.firstIndex(where: { $0 <= playbackTime }) {
            return freeLane
        }
        return lanes.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
    }
    
    private func yPosition(for item: ActiveDanmaku, viewportSize: CGSize, metrics: DanmakuLayoutMetrics) -> CGFloat {
        let laneHeight = item.fontSize * 1.5
        switch item.region {
        case .scroll:
            return metrics.topInset + laneHeight * CGFloat(item.lane + 1)
        case .top:
            return metrics.topInset + laneHeight * CGFloat(item.lane + 1)
        case .bottom:
            return viewportSize.height - metrics.bottomInset - laneHeight * CGFloat(item.lane + 1)
        }
    }
    
    private func resolvedFontSize(for viewportSize: CGSize) -> CGFloat {
        max(18, min(30, viewportSize.height * 0.034))
    }
}

private extension Array {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
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
