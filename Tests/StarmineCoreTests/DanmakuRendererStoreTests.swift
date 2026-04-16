import XCTest
@testable import StarmineCore

@MainActor
final class DanmakuRendererStoreTests: XCTestCase {
    func testSyncActivatesCommentsWhenPlaybackReachesCommentTime() {
        let store = DanmakuRendererStore()
        store.load([
            DanmakuComment(time: 1.0, text: "hello", presentation: .scroll, color: .white),
            DanmakuComment(time: 2.0, text: "world", presentation: .top, color: .white),
        ])

        store.sync(playbackTime: 0.5, viewportSize: CGSize(width: 1920, height: 1080))
        XCTAssertTrue(store.activeItems.isEmpty)

        store.sync(playbackTime: 1.0, viewportSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(store.activeItems.map(\.comment.text), ["hello"])
    }

    func testSyncResetsAfterBackwardSeek() {
        let store = DanmakuRendererStore()
        store.load([
            DanmakuComment(time: 1.0, text: "first", presentation: .scroll, color: .white),
            DanmakuComment(time: 3.0, text: "second", presentation: .scroll, color: .white),
        ])

        store.sync(playbackTime: 3.2, viewportSize: CGSize(width: 1280, height: 720))
        XCTAssertFalse(store.activeItems.isEmpty)

        store.sync(playbackTime: 1.0, viewportSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(store.activeItems.map(\.comment.text), ["first"])
    }

    func testScrollPointMovesLeftAsTimeAdvances() {
        let store = DanmakuRendererStore()
        store.load([
            DanmakuComment(time: 0.0, text: "moving", presentation: .scroll, color: .white),
        ])
        let viewport = CGSize(width: 1280, height: 720)
        store.sync(playbackTime: 0.0, viewportSize: viewport)

        guard let item = store.activeItems.first else {
            return XCTFail("expected active danmaku item")
        }

        let startPoint = store.point(for: item, playbackTime: 0.2, viewportSize: viewport)
        let laterPoint = store.point(for: item, playbackTime: 4.0, viewportSize: viewport)
        XCTAssertGreaterThan(startPoint.x, laterPoint.x)
    }

    func testDenseScrollDanmakuDelaysReuseOfBusyLaneToAvoidOverlap() {
        let store = DanmakuRendererStore()
        store.load([
            DanmakuComment(time: 0.00, text: "第一条弹幕特别长特别长特别长", presentation: .scroll, color: .white),
            DanmakuComment(time: 0.05, text: "第二条弹幕特别长特别长特别长", presentation: .scroll, color: .white),
            DanmakuComment(time: 0.10, text: "第三条弹幕特别长特别长特别长", presentation: .scroll, color: .white),
            DanmakuComment(time: 0.15, text: "第四条弹幕特别长特别长特别长", presentation: .scroll, color: .white),
            DanmakuComment(time: 0.20, text: "第五条弹幕特别长特别长特别长", presentation: .scroll, color: .white),
            DanmakuComment(time: 0.25, text: "第六条弹幕特别长特别长特别长", presentation: .scroll, color: .white),
        ])

        let viewport = CGSize(width: 1280, height: 180)
        store.sync(playbackTime: 0.25, viewportSize: viewport)

        let delayedItems = store.activeItems.filter { $0.region == .scroll && $0.startTime > $0.comment.time + 0.01 }
        XCTAssertFalse(delayedItems.isEmpty)

        let reusedLaneItems = Dictionary(grouping: store.activeItems.filter { $0.region == .scroll }, by: \.lane)
            .values
            .first(where: { $0.count > 1 })?
            .sorted { $0.startTime < $1.startTime }

        guard let reusedLaneItems, reusedLaneItems.count >= 2 else {
            return XCTFail("expected at least one reused scroll lane")
        }

        let sampleTime = reusedLaneItems[1].startTime + 0.12
        let firstPoint = store.point(for: reusedLaneItems[0], playbackTime: sampleTime, viewportSize: viewport)
        let secondPoint = store.point(for: reusedLaneItems[1], playbackTime: sampleTime, viewportSize: viewport)

        let firstRightEdge = firstPoint.x + reusedLaneItems[0].widthEstimate / 2
        let secondLeftEdge = secondPoint.x - reusedLaneItems[1].widthEstimate / 2
        XCTAssertGreaterThanOrEqual(secondLeftEdge, firstRightEdge - 1)
    }

    func testImmersiveMetricsStartScrollDanmakuAtViewportRightEdge() {
        let store = DanmakuRendererStore()
        store.load([
            DanmakuComment(time: 0.0, text: "fullscreen", presentation: .scroll, color: .white),
        ])

        let viewport = CGSize(width: 844, height: 390)
        store.sync(
            playbackTime: 0.0,
            viewportSize: viewport,
            metrics: .immersivePlayback
        )

        guard let item = store.activeItems.first else {
            return XCTFail("expected active danmaku item")
        }

        let startPoint = store.point(
            for: item,
            playbackTime: item.startTime,
            viewportSize: viewport,
            metrics: .immersivePlayback
        )

        XCTAssertEqual(
            startPoint.x,
            viewport.width + item.widthEstimate / 2,
            accuracy: 0.001
        )
    }

    func testPlaybackChromeMetricsApplyHorizontalInsetWithoutShrinkingEntryPoint() {
        let store = DanmakuRendererStore()
        store.load([
            DanmakuComment(time: 0.0, text: "chrome", presentation: .scroll, color: .white),
        ])

        let viewport = CGSize(width: 844, height: 390)
        store.sync(
            playbackTime: 0.0,
            viewportSize: viewport,
            metrics: .playbackChrome
        )

        guard let item = store.activeItems.first else {
            return XCTFail("expected active danmaku item")
        }

        let startPoint = store.point(
            for: item,
            playbackTime: item.startTime,
            viewportSize: viewport,
            metrics: .playbackChrome
        )

        XCTAssertEqual(
            startPoint.x,
            viewport.width - DanmakuLayoutMetrics.playbackChrome.horizontalInset + item.widthEstimate / 2,
            accuracy: 0.001
        )
    }

    func testCustomConfigurationChangesFontSizeAndDisplayAreaPlacement() {
        let store = DanmakuRendererStore(
            configuration: DanmakuRenderConfiguration(
                fontStyle: .systemSans,
                fontSize: 36,
                displayArea: .half
            )
        )
        store.load([
            DanmakuComment(time: 0.0, text: "scroll", presentation: .scroll, color: .white),
            DanmakuComment(time: 0.0, text: "bottom", presentation: .bottom, color: .white),
        ])

        let viewport = CGSize(width: 1280, height: 720)
        store.sync(playbackTime: 0.0, viewportSize: viewport)

        guard
            let scrollItem = store.activeItems.first(where: { $0.region == .scroll }),
            let bottomItem = store.activeItems.first(where: { $0.region == .bottom })
        else {
            return XCTFail("expected active scroll and bottom danmaku items")
        }

        XCTAssertEqual(scrollItem.fontSize, 36, accuracy: 0.001)
        let bottomPoint = store.point(
            for: bottomItem,
            playbackTime: 0.0,
            viewportSize: viewport
        )
        XCTAssertLessThan(
            bottomPoint.y,
            viewport.height - DanmakuLayoutMetrics.playbackChrome.bottomInset - 20
        )
    }
}
