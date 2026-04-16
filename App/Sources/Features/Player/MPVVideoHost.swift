import SwiftUI

#if os(macOS)
    import AppKit
    import QuartzCore

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
                if retiredViews.count > 8 {
                    retiredViews.removeFirst(retiredViews.count - 8)
                }
            }
            activeView = view
            return view
        }

        func remountHost() {
            mountToken = UUID()
        }
    }

    struct MPVVideoHostRepresentable: NSViewRepresentable {
        let player: MPVPlayerController
        @ObservedObject var host: MPVVideoHostBridge

        func makeNSView(context: Context) -> MPVVideoHostView {
            let view = host.makeView()
            view.onReady = player.attachHost
            return view
        }

        func updateNSView(_ nsView: MPVVideoHostView, context: Context) {
            nsView.onReady = player.attachHost
            nsView.notifyReady()
        }
    }

    final class MPVVideoHostView: NSView {
        var onReady: ((Int64) -> Void)?
        private let metalLayer = MPVMetalLayer()
        private var windowObservers: [NSObjectProtocol] = []
        private var lastViewportSize: CGSize = .zero
        private var lastViewportScale: CGFloat = 0

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

        func deactivate() {
            onReady = nil
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

        func notifyReady() {
            let pointer = Int64(
                Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque())
            )
            onReady?(pointer)
        }

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

        private func scheduleLayerSync(forceNotify: Bool) {
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

        private func syncViewportAndNotifyIfNeeded() {
            if syncMetalLayerSize() {
                notifyReady()
            }
        }

        @discardableResult
        private func syncMetalLayerSize() -> Bool {
            let size = bounds.size
            let scale =
                window?.backingScaleFactor ?? window?.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 1
            let viewportChanged =
                size != lastViewportSize || scale != lastViewportScale
            lastViewportSize = size
            lastViewportScale = scale

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.contentsScale = scale
            metalLayer.frame = CGRect(origin: .zero, size: size)
            metalLayer.drawableSize = CGSize(
                width: size.width * scale,
                height: size.height * scale
            )
            CATransaction.commit()
            return viewportChanged
        }
    }

    private final class MPVMetalLayer: CAMetalLayer {
        override var drawableSize: CGSize {
            get { super.drawableSize }
            set {
                if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                    super.drawableSize = newValue
                }
            }
        }

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
    }
#else
    import UIKit

    final class MPVVideoHostBridge: ObservableObject {
        @Published private(set) var mountToken = UUID()
        private var activeView: MPVVideoHostView?
        private var retiredViews: [MPVVideoHostView] = []

        func makeView() -> MPVVideoHostView {
            let view = MPVVideoHostView()
            if let activeView {
                retiredViews.append(activeView)
                if retiredViews.count > 3 {
                    retiredViews.removeFirst(retiredViews.count - 3)
                }
            }
            activeView = view
            return view
        }

        func remountHost() {
            mountToken = UUID()
        }
    }

    struct MPVVideoHostRepresentable: UIViewRepresentable {
        let player: MPVPlayerController
        @ObservedObject var host: MPVVideoHostBridge

        func makeUIView(context: Context) -> MPVVideoHostView {
            let view = host.makeView()
            view.onReady = player.attachHost
            return view
        }

        func updateUIView(_ uiView: MPVVideoHostView, context: Context) {
            uiView.onReady = player.attachHost
            uiView.notifyReady()
        }
    }

    final class MPVVideoHostView: UIView {
        var onReady: ((Int64) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            notifyReady()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            notifyReady()
        }

        func notifyReady() {
            let pointer = Int64(
                Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())
            )
            onReady?(pointer)
        }
    }
#endif
