import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif
import QuartzCore

private let retiredHostLimit = 8

final class MPVVideoHostBridge: ObservableObject {
    @Published private(set) var mountToken = UUID()
    private var activeView: MPVVideoHostView?
    private var retiredViews: [MPVVideoHostView] = []

    func makeView() -> MPVVideoHostView {
        let view = MPVVideoHostView()
        if let activeView {
            activeView.deactivate()
            // Keep a few detached hosts alive because mpv switches the wid target
            // asynchronously and its VO thread can still touch the previous layer.
            retiredViews.append(activeView)
            if retiredViews.count > retiredHostLimit {
                retiredViews.removeFirst(retiredViews.count - retiredHostLimit)
            }
        }
        activeView = view
        return view
    }

    func remountHost() {
        mountToken = UUID()
    }
}

@discardableResult
private func bindHostView(
    _ view: MPVVideoHostView,
    to player: MPVPlayerController
) -> MPVVideoHostView {
    view.onReady = player.attachHost
    view.notifyReady()
    return view
}

#if os(macOS)
    struct MPVVideoHostRepresentable: NSViewRepresentable {
        let player: MPVPlayerController
        @ObservedObject var host: MPVVideoHostBridge

        func makeNSView(context: Context) -> MPVVideoHostView {
            bindHostView(host.makeView(), to: player)
        }

        func updateNSView(_ nsView: MPVVideoHostView, context: Context) {
            bindHostView(nsView, to: player)
        }
    }
#else
    struct MPVVideoHostRepresentable: UIViewRepresentable {
        let player: MPVPlayerController
        @ObservedObject var host: MPVVideoHostBridge

        func makeUIView(context: Context) -> MPVVideoHostView {
            bindHostView(host.makeView(), to: player)
        }

        func updateUIView(_ uiView: MPVVideoHostView, context: Context) {
            bindHostView(uiView, to: player)
        }
    }
#endif

fileprivate struct MPVMetalViewportState {
    var lastViewportSize: CGSize = .zero
    var lastViewportScale: CGFloat = 0

    mutating func sync(
        metalLayer: MPVMetalLayer,
        bounds: CGRect,
        scale: CGFloat,
        applyHostContentsScale: (CGFloat) -> Void
    ) -> Bool {
        let size = bounds.size
        let viewportChanged =
            size != lastViewportSize || scale != lastViewportScale
        lastViewportSize = size
        lastViewportScale = scale
        // Round up so the drawable never ends up one pixel smaller than the
        // render target during animated layout transitions on iOS.
        let pixelSize = CGSize(
            width: max(1, ceil(size.width * scale)),
            height: max(1, ceil(size.height * scale))
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyHostContentsScale(scale)
        metalLayer.contentsScale = scale
        metalLayer.frame = CGRect(origin: .zero, size: size)
        metalLayer.drawableSize = pixelSize
        CATransaction.commit()

        return viewportChanged
    }
}

fileprivate protocol MPVMetalHostingView: AnyObject {
    var onReady: ((Int64) -> Void)? { get set }
    var metalLayer: MPVMetalLayer { get }
    var viewportState: MPVMetalViewportState { get set }
    var hostBounds: CGRect { get }

    func resolvedContentsScale() -> CGFloat
    func applyHostContentsScale(_ scale: CGFloat)
}

fileprivate extension MPVMetalHostingView {
    func deactivate() {
        onReady = nil
    }

    func notifyReady() {
        let pointer = Int64(
            Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque())
        )
        onReady?(pointer)
    }

    func scheduleLayerSync(forceNotify: Bool) {
        let viewportChanged = syncMetalLayerSize()
        if forceNotify || viewportChanged {
            notifyReady()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let viewportChanged = self.syncMetalLayerSize()
            if forceNotify || viewportChanged {
                self.notifyReady()
            }
        }
    }

    func syncViewportAndNotifyIfNeeded() {
        if syncMetalLayerSize() {
            notifyReady()
        }
    }

    @discardableResult
    func syncMetalLayerSize() -> Bool {
        var viewportState = viewportState
        let viewportChanged = viewportState.sync(
            metalLayer: metalLayer,
            bounds: hostBounds,
            scale: resolvedContentsScale(),
            applyHostContentsScale: applyHostContentsScale
        )
        self.viewportState = viewportState
        return viewportChanged
    }
}

#if os(macOS)
    final class MPVVideoHostView: NSView, MPVMetalHostingView {
        var onReady: ((Int64) -> Void)?
        fileprivate let metalLayer = MPVMetalLayer()
        fileprivate var viewportState = MPVMetalViewportState()
        private var windowObservers: [NSObjectProtocol] = []

        var hostBounds: CGRect { bounds }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .duringViewResize
            metalLayer.backgroundColor = NSColor.black.cgColor
            metalLayer.isOpaque = true
            metalLayer.framebufferOnly = true
            metalLayer.needsDisplayOnBoundsChange = true
            layer = metalLayer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            tearDownWindowObservers()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                deactivate()
                tearDownWindowObservers()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installWindowObserversIfNeeded()
            scheduleLayerSync(forceNotify: true)
        }

        override func layout() {
            super.layout()
            syncViewportAndNotifyIfNeeded()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            scheduleLayerSync(forceNotify: true)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            syncViewportAndNotifyIfNeeded()
        }

        override func setBoundsSize(_ newSize: NSSize) {
            super.setBoundsSize(newSize)
            syncViewportAndNotifyIfNeeded()
        }

        func resolvedContentsScale() -> CGFloat {
            window?.backingScaleFactor ?? window?.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 1
        }

        func applyHostContentsScale(_ scale: CGFloat) {}

        private func installWindowObserversIfNeeded() {
            guard windowObservers.isEmpty, let window else { return }

            let center = NotificationCenter.default
            let notificationNames: [NSNotification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]

            windowObservers = notificationNames.map { name in
                center.addObserver(forName: name, object: window, queue: .main)
                { [weak self] _ in
                    self?.scheduleLayerSync(forceNotify: true)
                }
            }
        }

        private func tearDownWindowObservers() {
            let center = NotificationCenter.default
            for observer in windowObservers {
                center.removeObserver(observer)
            }
            windowObservers.removeAll()
        }
    }
#else
    final class MPVVideoHostView: UIView, MPVMetalHostingView {
        var onReady: ((Int64) -> Void)?
        fileprivate let metalLayer = MPVMetalLayer()
        fileprivate var viewportState = MPVMetalViewportState()

        var hostBounds: CGRect { bounds }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            isOpaque = true
            metalLayer.backgroundColor = UIColor.black.cgColor
            metalLayer.isOpaque = true
            metalLayer.framebufferOnly = true
            metalLayer.needsDisplayOnBoundsChange = true
            layer.addSublayer(metalLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil {
                deactivate()
            }
            super.willMove(toWindow: newWindow)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleLayerSync(forceNotify: true)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            syncViewportAndNotifyIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            scheduleLayerSync(forceNotify: true)
        }

        override func traitCollectionDidChange(
            _ previousTraitCollection: UITraitCollection?
        ) {
            super.traitCollectionDidChange(previousTraitCollection)
            scheduleLayerSync(forceNotify: true)
        }

        func resolvedContentsScale() -> CGFloat {
            window?.screen.scale ?? UIScreen.main.scale
        }

        func applyHostContentsScale(_ scale: CGFloat) {
            contentScaleFactor = scale
        }
    }
#endif

fileprivate final class MPVMetalLayer: CAMetalLayer {
    override func action(forKey event: String) -> CAAction? {
        if Thread.isMainThread {
            return super.action(forKey: event)
        }
        return nil
    }

    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    #if os(macOS)
        // mpv toggles this from its render thread when target-colorspace-hint is enabled.
        // AppKit only applies the EDR transition reliably when the layer mutation happens on main.
        override var wantsExtendedDynamicRangeContent: Bool {
            get { super.wantsExtendedDynamicRangeContent }
            set {
                if Thread.isMainThread {
                    super.wantsExtendedDynamicRangeContent = newValue
                } else {
                    DispatchQueue.main.sync {
                        super.wantsExtendedDynamicRangeContent = newValue
                    }
                }
            }
        }
    #endif
}
