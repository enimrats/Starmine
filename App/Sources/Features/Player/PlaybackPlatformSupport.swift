import SwiftUI

#if os(macOS)
    import AppKit

    struct WindowToolbarFullscreenBehavior: ViewModifier {
        let isVideoFullscreen: Bool

        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(macOS 15.0, *) {
                content.windowToolbarFullScreenVisibility(
                    isVideoFullscreen ? .onHover : .visible
                )
            } else {
                content
            }
        }
    }

    struct PlaybackShortcutMonitor: NSViewRepresentable {
        let onTogglePause: () -> Void
        let onToggleFullscreen: () -> Void
        let onWindowWillClose: () -> Void

        func makeNSView(context: Context) -> PlaybackShortcutMonitorView {
            let view = PlaybackShortcutMonitorView()
            view.onTogglePause = onTogglePause
            view.onToggleFullscreen = onToggleFullscreen
            view.onWindowWillClose = onWindowWillClose
            return view
        }

        func updateNSView(
            _ nsView: PlaybackShortcutMonitorView,
            context: Context
        ) {
            nsView.onTogglePause = onTogglePause
            nsView.onToggleFullscreen = onToggleFullscreen
            nsView.onWindowWillClose = onWindowWillClose
        }
    }

    final class PlaybackShortcutMonitorView: NSView {
        var onTogglePause: (() -> Void)?
        var onToggleFullscreen: (() -> Void)?
        var onWindowWillClose: (() -> Void)?
        private var localMonitor: Any?
        private var willCloseObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMonitorIfNeeded()
            installWindowObserverIfNeeded()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                tearDownWindowObserver()
                tearDownMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        deinit {
            tearDownWindowObserver()
            tearDownMonitor()
        }

        private func installMonitorIfNeeded() {
            guard localMonitor == nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown)
            { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func tearDownMonitor() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
            }
            localMonitor = nil
        }

        private func installWindowObserverIfNeeded() {
            guard willCloseObserver == nil, let window else { return }
            willCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onWindowWillClose?()
            }
        }

        private func tearDownWindowObserver() {
            if let willCloseObserver {
                NotificationCenter.default.removeObserver(willCloseObserver)
            }
            willCloseObserver = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard window?.isKeyWindow == true else { return event }
            guard window?.firstResponder is NSTextView == false else {
                return event
            }
            let blockedModifiers: NSEvent.ModifierFlags = [
                .command, .control, .option,
            ]
            guard event.modifierFlags.intersection(blockedModifiers).isEmpty
            else { return event }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ":
                onTogglePause?()
                return nil
            case "f":
                onToggleFullscreen?()
                return nil
            default:
                return event
            }
        }
    }
#endif
