import Combine
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

private enum MobileRootTab: Hashable {
    case home
    case files
    case library
    case player
}

struct RootView: View {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var playbackHost = MPVVideoHostBridge()
    @State private var importerPresented = false
    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false
    @State private var pendingSeekPosition: Double?
    @State private var pendingSeekResetTask: Task<Void, Never>?
    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
    @State private var playbackChromeVisible = false
    @State private var playbackChromeAutoHideTask: Task<Void, Never>?
    @State private var workspaceSection: WorkspaceSection = .home
    @State private var jellyfinLibrarySearch = ""
    @State private var hasActivePlayback = false
    @State private var lastObservedPlaybackURL: URL?
    @State private var currentPlaybackTitle = "Starmine"
    @State private var currentPlaybackEpisodeLabel = ""
    @State private var playbackDanmakuEnabled = true
    @State private var playbackIsRemote = false
    @State private var playbackPaused = true
    @State private var playbackVideoAspect = 0.0
    @State private var selectedAudioTrackTitle: String?
    @State private var selectedSubtitleTrackTitle: String?
    @State private var lastPlaybackSurfaceSize: CGSize = .zero
    @State private var playbackHostRemountTask: Task<Void, Never>?
    #if !os(macOS)
        @State private var mobileTab: MobileRootTab = .home
        @State private var isIOSVideoFullscreen = false
        @State private var mobileDanmakuSheetPresented = false
    #endif
    #if os(macOS)
        @State private var isWindowFullscreen = false
        @State private var isVideoFullscreen = false
        @State private var pendingVideoFullscreenEntry = false
        @State private var videoFullscreenOwnsWindowFullscreen = false
        @State private var splitViewVisibilityBeforeVideoFullscreen:
            NavigationSplitViewVisibility?
    #endif

    private var playback: PlaybackStore { coordinator.playback }
    private var danmaku: DanmakuFeatureStore { coordinator.danmaku }
    private var jellyfin: JellyfinStore { coordinator.jellyfin }

    var body: some View {
        rootContent
            .fileImporter(
                isPresented: $importerPresented,
                allowedContentTypes: [
                    .movie, .video, .mpeg4Movie, .quickTimeMovie,
                ],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    coordinator.openVideo(url: url)
                case let .failure(error):
                    coordinator.errorState = AppErrorState(
                        message: error.localizedDescription
                    )
                }
            }
            .alert(item: $coordinator.errorState) { errorState in
                Alert(title: Text("请求失败"), message: Text(errorState.message))
            }
            .onReceive(playback.$snapshot.map(\.position).removeDuplicates()) {
                newValue in
                guard !isScrubbing else { return }
                if let pendingSeekPosition {
                    if abs(newValue - pendingSeekPosition) <= 0.75 {
                        clearPendingSeek(syncTo: newValue)
                    }
                }
            }
            .onReceive(playback.$currentVideoURL.removeDuplicates()) {
                newValue in
                let previousValue = lastObservedPlaybackURL
                lastObservedPlaybackURL = newValue
                hasActivePlayback = newValue != nil
                // Ignore repeated current-value emissions when SwiftUI rebuilds the view.
                guard previousValue != newValue else { return }
                clearPendingSeek(syncTo: 0)
                if newValue == nil {
                    #if os(macOS)
                        dismissVideoFullscreenIfNeeded()
                    #else
                        setIOSVideoFullscreen(false)
                        mobileDanmakuSheetPresented = false
                    #endif
                    hidePlaybackChrome()
                    if let activeID = coordinator.activeJellyfinAccount?.id {
                        workspaceSection = .library(activeID)
                        #if !os(macOS)
                            mobileTab = .library
                        #endif
                    } else {
                        workspaceSection = .home
                        #if !os(macOS)
                            mobileTab = .home
                        #endif
                    }
                } else {
                    workspaceSection = .player
                    #if !os(macOS)
                        mobileTab = .player
                        showPlaybackChrome()
                        schedulePlaybackChromeAutoHide()
                    #endif
                }
            }
            .onReceive(playback.$currentVideoTitle.removeDuplicates()) {
                newValue in
                currentPlaybackTitle = newValue
            }
            .onReceive(playback.$currentEpisodeLabel.removeDuplicates()) {
                newValue in
                currentPlaybackEpisodeLabel = newValue
            }
            .onReceive(playback.$danmakuEnabled.removeDuplicates()) {
                newValue in
                playbackDanmakuEnabled = newValue
            }
            .onReceive(playback.$isPlayingRemote.removeDuplicates()) {
                newValue in
                playbackIsRemote = newValue
            }
            #if !os(macOS)
                .onAppear {
                    guard !isIOSVideoFullscreen else { return }
                    StarmineiOSOrientationController
                        .restoreDefaultOrientationBehavior()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didBecomeActiveNotification
                    )
                ) { _ in
                    guard !isIOSVideoFullscreen else { return }
                    StarmineiOSOrientationController
                        .restoreDefaultOrientationBehavior()
                }
            #endif
            .onReceive(
                playback.$snapshot.map(PlaybackSurfaceState.init(snapshot:))
                    .removeDuplicates()
            ) { state in
                playbackPaused = state.paused
                playbackVideoAspect = state.videoAspect
            }
            .onReceive(
                playback.$selectedAudioTrackID
                    .combineLatest(playback.$audioTracks)
                    .map { selectedID, tracks in
                        tracks.first(where: { $0.mpvID == selectedID })?.title
                    }
                    .removeDuplicates()
            ) { newValue in
                selectedAudioTrackTitle = newValue
            }
            .onReceive(
                playback.$selectedSubtitleTrackID
                    .combineLatest(playback.$subtitleTracks)
                    .map { selectedID, tracks in
                        tracks.first(where: { $0.mpvID == selectedID })?.title
                    }
                    .removeDuplicates()
            ) { newValue in
                selectedSubtitleTrackTitle = newValue
            }
            .onChange(of: jellyfin.selectedAccountID) { newValue in
                guard let newValue = newValue, !hasActivePlayback else { return }
                workspaceSection = .library(newValue)
                #if !os(macOS)
                    mobileTab = .library
                #endif
            }
            .onChange(of: jellyfin.selectedLibraryID) { _ in
                jellyfinLibrarySearch = ""
            }
            .onChange(of: workspaceSection) { newValue in
                #if !os(macOS)
                    switch newValue {
                    case .home: mobileTab = .home
                    case .files: mobileTab = .files
                    case .library: mobileTab = .library
                    case .player: mobileTab = .player
                    }
                #endif
            }
            #if !os(macOS)
                .onChange(of: mobileDanmakuSheetPresented) { presented in
                    if presented {
                        playbackHostRemountTask?.cancel()
                        playbackHostRemountTask = nil
                        cancelPlaybackChromeAutoHide()
                    } else if hasActivePlayback {
                        showPlaybackChrome()
                        schedulePlaybackChromeAutoHide()
                    }
                }
                .onChange(of: mobileTab) { newValue in
                    if newValue != .player, isIOSVideoFullscreen {
                        setIOSVideoFullscreen(false)
                    }
                    switch newValue {
                    case .home:
                        workspaceSection = .home
                    case .files:
                        workspaceSection = .files
                    case .library:
                        if let id = coordinator.activeJellyfinAccount?.id {
                            workspaceSection = .library(id)
                        }
                    case .player:
                        workspaceSection = .player
                    }
                }
            #endif
            .onDisappear {
                cancelPlaybackChromeAutoHide()
                pendingSeekResetTask?.cancel()
                pendingSeekResetTask = nil
                playbackHostRemountTask?.cancel()
                playbackHostRemountTask = nil
                #if os(macOS)
                    setPlaybackCursorHidden(false)
                #endif
            }
            #if os(macOS)
                .modifier(
                    WindowToolbarFullscreenBehavior(
                        isVideoFullscreen: isVideoFullscreen
                    )
                )
                .background(
                    PlaybackShortcutMonitor(
                        onTogglePause: {
                            guard hasActivePlayback else { return }
                            coordinator.togglePause()
                        },
                        onToggleFullscreen: {
                            guard hasActivePlayback else { return }
                            toggleVideoFullscreen()
                        },
                        onWindowWillClose: {
                            coordinator.handleWindowClosing()
                        }
                    )
                )
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSWindow.didEnterFullScreenNotification
                    )
                ) { _ in
                    isWindowFullscreen = true
                    playbackHostRemountTask?.cancel()
                    playbackHostRemountTask = nil
                    cancelPlaybackChromeAutoHide()
                    playbackChromeVisible = false
                    setPlaybackCursorHidden(false)
                    if pendingVideoFullscreenEntry {
                        pendingVideoFullscreenEntry = false
                        isVideoFullscreen = true
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSWindow.didExitFullScreenNotification
                    )
                ) { _ in
                    isWindowFullscreen = false
                    playbackHostRemountTask?.cancel()
                    playbackHostRemountTask = nil
                    cancelPlaybackChromeAutoHide()
                    playbackChromeVisible = false
                    setPlaybackCursorHidden(false)
                    if pendingVideoFullscreenEntry {
                        pendingVideoFullscreenEntry = false
                        videoFullscreenOwnsWindowFullscreen = false
                        restoreSplitViewVisibilityAfterVideoFullscreen()
                    } else if isVideoFullscreen
                        || videoFullscreenOwnsWindowFullscreen
                    {
                        videoFullscreenOwnsWindowFullscreen = false
                        isVideoFullscreen = false
                        restoreSplitViewVisibilityAfterVideoFullscreen()
                    } else {
                        videoFullscreenOwnsWindowFullscreen = false
                    }
                }
                .onChange(of: isWindowFullscreen) { _ in
                    playbackHost.remountHost()
                }
            #endif
    }

    @ViewBuilder
    private var rootContent: some View {
        #if os(macOS)
            if usesImmersivePlaybackRoot {
                detail
            } else {
                splitViewContent
            }
        #else
            mobileTabContent
        #endif
    }

    #if !os(macOS)
        private var mobileTabContent: some View {
            TabView(selection: $mobileTab) {
                NavigationStack {
                    ZStack {
                        Palette.canvas.ignoresSafeArea()
                        homeScreenPlaceholder
                    }
                    .navigationTitle("主页")
                }
                .tabItem {
                    Label("主页", systemImage: "house.fill")
                }
                .tag(MobileRootTab.home)

                NavigationStack {
                    FilesWorkspaceView(
                        coordinator: coordinator,
                        jellyfin: jellyfin,
                        importerPresented: $importerPresented,
                        workspaceSection: $workspaceSection,
                        prefersTouchLayout: true
                    )
                    .navigationTitle("文件")
                }
                .tabItem {
                    Label("文件", systemImage: "folder.fill")
                }
                .tag(MobileRootTab.files)

                NavigationStack {
                    mobileLibraryScreen
                }
                .tabItem {
                    Label(
                        "媒体库",
                        systemImage: "rectangle.stack.badge.play.fill"
                    )
                }
                .tag(MobileRootTab.library)

                NavigationStack {
                    mobilePlayerScreen
                }
                .tabItem {
                    Label(
                        "播放器",
                        systemImage: hasActivePlayback
                            ? "play.rectangle.fill" : "play.rectangle"
                    )
                }
                .tag(MobileRootTab.player)
            }
            .tint(Palette.accentDeep)
        }

        private var mobileLibraryScreen: some View {
            ZStack {
                Palette.canvas.ignoresSafeArea()

                LibraryWorkspaceView(
                    coordinator: coordinator,
                    jellyfin: jellyfin,
                    hasActivePlayback: hasActivePlayback,
                    workspaceSection: $workspaceSection,
                    jellyfinLibrarySearch: $jellyfinLibrarySearch,
                    showsInlineSelectionToolbar: true,
                    prefersTouchLayout: true
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .navigationTitle("媒体库")
            .toolbar {
                if hasActivePlayback {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            mobileTab = .player
                        } label: {
                            Image(systemName: "play.rectangle.fill")
                        }
                    }
                }
            }
        }

        private var mobilePlayerScreen: some View {
            ZStack {
                (hasActivePlayback ? Color.black : Palette.canvas)
                    .ignoresSafeArea()

                if hasActivePlayback {
                    GeometryReader { proxy in
                        playbackStage(
                            in: proxy.size,
                            isImmersive: isIOSVideoFullscreen
                                || proxy.size.width > proxy.size.height
                        )
                    }
                    .ignoresSafeArea(
                        .container,
                        edges: isIOSVideoFullscreen ? .all : []
                    )
                } else {
                    placeholder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 24)
                }
            }
            .navigationTitle("播放器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(
                isIOSVideoFullscreen ? .hidden : .visible,
                for: .navigationBar
            )
            .toolbar(isIOSVideoFullscreen ? .hidden : .visible, for: .tabBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(
                hasActivePlayback ? Color.black.opacity(0.92) : Palette.canvas,
                for: .navigationBar
            )
            .toolbarColorScheme(
                hasActivePlayback ? .dark : .light,
                for: .navigationBar
            )
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if hasActivePlayback {
                        Button {
                            showMobileDanmakuSheet()
                        } label: {
                            Image(systemName: "text.magnifyingglass")
                        }
                    }

                    Button {
                        importerPresented = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }

                    if coordinator.activeJellyfinAccount != nil {
                        Button {
                            mobileTab = .library
                        } label: {
                            Image(systemName: "rectangle.stack.badge.play.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $mobileDanmakuSheetPresented) {
                mobileDanmakuSheet
            }
        }

        private var mobileDanmakuSheet: some View {
            NavigationStack {
                ScrollView {
                    if hasActivePlayback {
                        DanmakuPanelView(
                            coordinator: coordinator,
                            playback: playback,
                            danmaku: danmaku,
                            prefersTouchLayout: true
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 28)
                    } else {
                        Text("开始播放后再替换弹幕。")
                            .font(
                                .system(
                                    size: 15,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                }
                .background(Palette.sidebarBackground.ignoresSafeArea())
                .navigationTitle("弹幕")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") {
                            mobileDanmakuSheetPresented = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    #endif

    #if os(macOS)
        private var splitViewContent: some View {
            NavigationSplitView(columnVisibility: $splitViewVisibility) {
                SidebarView(
                    coordinator: coordinator,
                    playback: playback,
                    danmaku: danmaku,
                    jellyfin: jellyfin,
                    importerPresented: $importerPresented,
                    workspaceSection: $workspaceSection
                )
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
        }
    #endif

    private var detail: some View {
        ZStack {
            (usesImmersivePlaybackLayout ? Color.black : Palette.canvas)
                .ignoresSafeArea()

            if usesImmersivePlaybackLayout {
                playbackWorkspace
            } else {
                VStack(spacing: 18) {
                    workspaceHeader
                        .padding(.horizontal, 24)
                        .padding(.top, 20)

                    switch workspaceSection {
                    case .home:
                        homeScreenPlaceholder
                    case .files:
                        FilesWorkspaceView(
                            coordinator: coordinator,
                            jellyfin: jellyfin,
                            importerPresented: $importerPresented,
                            workspaceSection: $workspaceSection,
                            prefersTouchLayout: false
                        )
                    case .library:
                        LibraryWorkspaceView(
                            coordinator: coordinator,
                            jellyfin: jellyfin,
                            hasActivePlayback: hasActivePlayback,
                            workspaceSection: $workspaceSection,
                            jellyfinLibrarySearch: $jellyfinLibrarySearch
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    case .player:
                        playbackWorkspace
                    }
                }
            }
        }
        .toolbar {
            if !usesImmersivePlaybackLayout, workspaceSection == .player {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        importerPresented = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }

                    Button {
                        playback.danmakuEnabled.toggle()
                    } label: {
                        Image(
                            systemName: playbackDanmakuEnabled
                                ? "text.bubble.fill" : "text.bubble"
                        )
                    }

                    #if os(macOS)
                        Button {
                            toggleVideoFullscreen()
                        } label: {
                            Image(
                                systemName: isVideoFullscreen
                                    ? "arrow.down.right.and.arrow.up.left"
                                    : "arrow.up.left.and.arrow.down.right"
                            )
                        }
                        .disabled(!hasActivePlayback)
                    #endif
                }
            }
        }
    }

    @ViewBuilder
    private var playbackWorkspace: some View {
        if !hasActivePlayback {
            placeholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                playbackStage(
                    in: proxy.size,
                    isImmersive: usesImmersivePlaybackLayout
                )
            }
        }
    }

    private func playbackStage(in containerSize: CGSize, isImmersive: Bool)
        -> some View
    {
        let outerPadding: CGFloat = isImmersive ? 0 : 24
        let cornerRadius: CGFloat = isImmersive ? 0 : 30
        let surfaceSize = CGSize(
            width: max(0, containerSize.width - outerPadding * 2),
            height: max(0, containerSize.height - outerPadding * 2)
        )
        let videoRect = fittedVideoRect(in: surfaceSize)
        let danmakuMetrics: DanmakuLayoutMetrics =
            isImmersive ? .immersivePlayback : .playbackChrome

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black)

            MPVVideoHostRepresentable(
                player: playback.player,
                host: playbackHost
            )
            .id(playbackHost.mountToken)
            .frame(width: surfaceSize.width, height: surfaceSize.height)
            .background(Color.black)
            .allowsHitTesting(false)

            if playbackDanmakuEnabled, surfaceSize.width > 0, surfaceSize.height > 0
            {
                danmakuOverlay(in: surfaceSize, metrics: danmakuMetrics)
                    .frame(width: surfaceSize.width, height: surfaceSize.height)
                    .clipped()
                    .allowsHitTesting(false)
            }

            playbackChromeOverlay(
                in: surfaceSize,
                videoRect: videoRect,
                isImmersive: isImmersive
            )
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height)
        .contentShape(Rectangle())
        .onAppear {
            handlePlaybackSurfaceSizeChange(surfaceSize)
        }
        .onChange(of: surfaceSize) { newValue in
            handlePlaybackSurfaceSizeChange(newValue)
        }
        #if os(macOS)
            .onContinuousHover { phase in
                updatePlaybackChrome(for: phase)
            }
        #endif
        .clipShape(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                .opacity(isImmersive ? 0 : 1)
        }
        .shadow(
            color: .black.opacity(isImmersive ? 0 : 0.16),
            radius: isImmersive ? 0 : 24,
            x: 0,
            y: isImmersive ? 0 : 10
        )
        .padding(outerPadding)
        #if os(macOS)
            .onTapGesture(count: 2) {
                toggleVideoFullscreen()
            }
        #else
            .onTapGesture {
                handlePlaybackSurfaceTap()
            }
        #endif
    }

    private var placeholder: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Palette.accent.opacity(0.18), Palette.selection,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 200, height: 200)
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(Palette.accentDeep)
            }

            Button {
                importerPresented = true
            } label: {
                Text("打开视频")
                    .font(
                        .system(size: 18, weight: .semibold, design: .rounded)
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accentDeep)

            if let activeAccountID = coordinator.activeJellyfinAccount?.id {
                Button {
                    workspaceSection = .library(activeAccountID)
                } label: {
                    Label("进入媒体库", systemImage: "rectangle.stack.fill")
                        .font(
                            .system(
                                size: 15,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
            }
        }
    }

    
    private var homeScreenPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Palette.accent.opacity(0.8))
            Text("欢迎使用 Starmine")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("播放状态跟踪与更多功能敬请期待。")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceHeaderTitle: String {
        switch workspaceSection {
        case .home: return "主页"
        case .files: return "文件"
        case .library: return "媒体库节目"
        case .player: return "播放器"
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 18) {
            if case .library = workspaceSection,
                coordinator.selectedJellyfinItem != nil
            {
                Button {
                    withAnimation(
                        .spring(response: 0.28, dampingFraction: 0.88)
                    ) {
                        coordinator.clearSelectedJellyfinItem()
                    }
                } label: {
                    Image(systemName: "chevron.backward.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(
                            Palette.accentDeep,
                            Palette.accent.opacity(0.18)
                        )
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(workspaceHeaderTitle)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                if !workspaceSummaryText.isEmpty {
                    Text(workspaceSummaryText)
                        .font(
                            .system(size: 13, weight: .medium, design: .rounded)
                        )
                        .foregroundStyle(Palette.ink.opacity(0.58))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            

            if let account = coordinator.activeJellyfinAccount {
                HeaderCapsule(
                    title: account.username,
                    systemImage: "person.crop.circle.fill"
                )
            }

            if let route = coordinator.activeJellyfinRoute {
                HeaderCapsule(
                    title: route.name,
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.78))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.6), lineWidth: 1)
        }
    }

    private var workspaceSummaryText: String {
        switch workspaceSection {
        case .home, .files:
            return ""
        case .library:
            if let item = coordinator.selectedJellyfinItem {
                return item.metaLine.isEmpty
                    ? item.name : "\(item.name) · \(item.metaLine)"
            }
            if let library = coordinator.selectedJellyfinLibrary {
                return "\(library.name) · \(library.subtitle)"
            }
            if let account = coordinator.activeJellyfinAccount {
                return account.displayTitle
            }
            return ""
        case .player:
            if hasActivePlayback {
                return currentPlaybackTitle
            }
            return ""
        }
    }

    private var topOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(currentPlaybackTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let selectedAnime = coordinator.selectedAnime {
                        PillLabel(text: selectedAnime.title)
                    }
                    if !currentPlaybackEpisodeLabel.isEmpty {
                        PillLabel(text: currentPlaybackEpisodeLabel)
                    }
                    if playbackIsRemote,
                        let route = coordinator.activeJellyfinRoute?.name
                    {
                        PillLabel(text: route)
                    }
                    if let selectedAudioTrackTitle {
                        PillLabel(text: selectedAudioTrackTitle)
                    }
                    if let selectedSubtitleTrackTitle {
                        PillLabel(text: selectedSubtitleTrackTitle)
                    }
                    if danmaku.isLoadingDanmaku {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, 4)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            LinearGradient(
                colors: [Color.black.opacity(0.84), Color.black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 124)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.black.opacity(0.86))
                    .frame(height: 6)
            }
            .offset(y: -3)
        }
    }

    @ViewBuilder
    private func playbackChromeOverlay(
        in surfaceSize: CGSize,
        videoRect: CGRect,
        isImmersive: Bool
    ) -> some View {
        let chromeRect = chromeRect(
            in: surfaceSize,
            videoRect: videoRect,
            isImmersive: isImmersive
        )

        VStack(spacing: 0) {
            topOverlay
            Spacer()
            controls(width: chromeRect.width)
        }
        .frame(width: chromeRect.width, height: chromeRect.height)
        .offset(x: chromeRect.origin.x, y: chromeRect.origin.y)
        .opacity(showsPlaybackChrome ? 1 : 0)
        .allowsHitTesting(showsPlaybackChrome)
        .animation(.easeInOut(duration: 0.18), value: showsPlaybackChrome)
    }

    private func controls(width: CGFloat) -> some View {
        let usesCompactLayout = showsCompactPlaybackControls(for: width)

        return VStack(spacing: usesCompactLayout ? 12 : 14) {
            playbackProgressStrip(showsInlineTimeLabels: usesCompactLayout)

            if usesCompactLayout {
                compactPlaybackControls()
            } else {
                regularPlaybackControls(width: width)
            }
        }
        .padding(.horizontal, usesCompactLayout ? 16 : 18)
        .padding(.vertical, usesCompactLayout ? 14 : 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black.opacity(0.74))
        )
        .padding(18)
    }

    private func playbackProgressStrip(showsInlineTimeLabels: Bool) -> some View
    {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 120.0,
                paused: playbackPaused || !hasActivePlayback
            )
        ) { context in
            let livePosition = resolvedPlaybackPosition(at: context.date)

            VStack(spacing: showsInlineTimeLabels ? 10 : 0) {
                PlaybackSeekBar(
                    duration: playback.snapshot.duration,
                    position: livePosition,
                    bufferedTint: .white,
                    onScrubStart: {
                        clearPendingSeek(syncTo: livePosition)
                        isScrubbing = true
                        cancelPlaybackChromeAutoHide()
                    },
                    onScrubChange: { value in
                        scrubPosition = value
                    },
                    onScrubEnd: { value in
                        beginOptimisticSeek(to: value)
                    }
                )

                if showsInlineTimeLabels {
                    compactPlaybackTimeLabels
                }
            }
        }
    }

    private var compactPlaybackTimeLabels: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 120.0,
                paused: playbackPaused || !hasActivePlayback
            )
        ) { context in
            let livePosition = resolvedPlaybackPosition(at: context.date)

            HStack {
                playbackTimeText(livePosition)
                Spacer(minLength: 12)
                playbackDurationText
            }
        }
    }

    private func regularPlaybackTimeLabels(width: CGFloat) -> some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 120.0,
                paused: playbackPaused || !hasActivePlayback
            )
        ) { context in
            let livePosition = resolvedPlaybackPosition(at: context.date)

            HStack(spacing: 0) {
                playbackTimeText(livePosition)

                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(width: max(24, width * 0.05), height: 4)
                    .padding(.horizontal, 14)

                playbackDurationText
            }
        }
    }

    private func regularPlaybackControls(width: CGFloat) -> some View {
        HStack(spacing: 14) {
            chromeButton(
                systemName: "backward.end.fill",
                disabled: !playback.canPlayPreviousEpisode
            ) {
                notePlaybackInteraction()
                coordinator.playPreviousEpisode()
            }
            chromeButton(
                systemName: playback.snapshot.paused
                    ? "play.fill" : "pause.fill"
            ) {
                notePlaybackInteraction()
                coordinator.togglePause()
            }
            chromeButton(
                systemName: "forward.end.fill",
                disabled: !playback.canPlayNextEpisode
            ) {
                notePlaybackInteraction()
                coordinator.playNextEpisode()
            }
            chromeButton(systemName: "gobackward.10") {
                beginOptimisticSeek(to: displayedPlaybackPosition - 10)
            }
            chromeButton(systemName: "goforward.10") {
                beginOptimisticSeek(to: displayedPlaybackPosition + 10)
            }

            regularPlaybackTimeLabels(width: width)

            Spacer(minLength: 12)

            trackMenu(
                title: playback.selectedAudioTrack?.title ?? "音轨",
                systemImage: "music.note",
                tracks: playback.audioTracks,
                selectedID: playback.selectedAudioTrackID,
                includeOffOption: false
            ) { id in
                if let id {
                    notePlaybackInteraction()
                    coordinator.selectAudioTrack(id: id)
                }
            }

            trackMenu(
                title: playback.selectedSubtitleTrack?.title ?? "字幕关闭",
                systemImage: "captions.bubble",
                tracks: playback.subtitleTracks,
                selectedID: playback.selectedSubtitleTrackID,
                includeOffOption: true
            ) { id in
                notePlaybackInteraction()
                coordinator.selectSubtitleTrack(id: id)
            }

            chromeButton(
                systemName: playbackDanmakuEnabled
                    ? "text.bubble.fill" : "text.bubble"
            ) {
                notePlaybackInteraction()
                playback.danmakuEnabled.toggle()
            }

            #if !os(macOS)
                chromeButton(systemName: "text.magnifyingglass") {
                    showMobileDanmakuSheet()
                }

                chromeButton(
                    systemName: isIOSVideoFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                ) {
                    notePlaybackInteraction()
                    toggleIOSVideoFullscreen()
                }
            #endif

            #if os(macOS)
                chromeButton(
                    systemName: isVideoFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                ) {
                    toggleVideoFullscreen()
                }
            #endif

            chromeButton(systemName: "folder") {
                notePlaybackInteraction()
                importerPresented = true
            }
        }
    }

    @ViewBuilder
    private func compactPlaybackControls() -> some View {
        #if !os(macOS)
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    chromeButton(
                        systemName: "backward.end.fill",
                        disabled: !playback.canPlayPreviousEpisode,
                        size: 32
                    ) {
                        notePlaybackInteraction()
                        coordinator.playPreviousEpisode()
                    }
                    chromeButton(systemName: "gobackward.10", size: 32) {
                        beginOptimisticSeek(to: displayedPlaybackPosition - 10)
                    }
                    chromeButton(
                        systemName: playback.snapshot.paused
                            ? "play.fill" : "pause.fill",
                        size: 44,
                        emphasized: true
                    ) {
                        notePlaybackInteraction()
                        coordinator.togglePause()
                    }
                    chromeButton(systemName: "goforward.10", size: 32) {
                        beginOptimisticSeek(to: displayedPlaybackPosition + 10)
                    }
                    chromeButton(
                        systemName: "forward.end.fill",
                        disabled: !playback.canPlayNextEpisode,
                        size: 32
                    ) {
                        notePlaybackInteraction()
                        coordinator.playNextEpisode()
                    }
                    chromeButton(systemName: "text.magnifyingglass", size: 32) {
                        showMobileDanmakuSheet()
                    }
                    chromeButton(
                        systemName: isIOSVideoFullscreen
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right",
                        size: 32
                    ) {
                        notePlaybackInteraction()
                        toggleIOSVideoFullscreen()
                    }
                    compactPlaybackActionsMenu
                }
            }
        #else
            EmptyView()
        #endif
    }

    @ViewBuilder
    private var compactPlaybackActionsMenu: some View {
        #if !os(macOS)
            Menu {
                Section("弹幕") {
                    Button {
                        showMobileDanmakuSheet()
                    } label: {
                        Label("搜索或替换弹幕", systemImage: "text.magnifyingglass")
                    }

                    Button {
                        notePlaybackInteraction()
                        playback.danmakuEnabled.toggle()
                    } label: {
                        Label(
                            playbackDanmakuEnabled ? "关闭弹幕" : "显示弹幕",
                            systemImage: playbackDanmakuEnabled
                                ? "text.bubble.fill" : "text.bubble"
                        )
                    }
                }

                Section("音轨与字幕") {
                    Menu {
                        ForEach(playback.audioTracks) { track in
                            trackMenuButton(
                                title: track.title,
                                detail: track.detail,
                                isSelected: playback.selectedAudioTrackID
                                    == track.mpvID
                            ) {
                                notePlaybackInteraction()
                                coordinator.selectAudioTrack(id: track.mpvID)
                            }
                        }
                    } label: {
                        Label("音轨", systemImage: "music.note")
                    }
                    .disabled(playback.audioTracks.isEmpty)

                    Menu {
                        trackMenuButton(
                            title: "关闭字幕",
                            detail: "",
                            isSelected: playback.selectedSubtitleTrackID == nil
                        ) {
                            notePlaybackInteraction()
                            coordinator.selectSubtitleTrack(id: nil)
                        }

                        ForEach(playback.subtitleTracks) { track in
                            trackMenuButton(
                                title: track.title,
                                detail: track.detail,
                                isSelected: playback.selectedSubtitleTrackID
                                    == track.mpvID
                            ) {
                                notePlaybackInteraction()
                                coordinator.selectSubtitleTrack(id: track.mpvID)
                            }
                        }
                    } label: {
                        Label("字幕", systemImage: "captions.bubble")
                    }
                }

                Section("更多") {
                    Button {
                        notePlaybackInteraction()
                        importerPresented = true
                    } label: {
                        Label("打开视频", systemImage: "folder.badge.plus")
                    }

                    if coordinator.activeJellyfinAccount != nil {
                        Button {
                            notePlaybackInteraction()
                            mobileTab = .library
                        } label: {
                            Label(
                                "前往媒体库",
                                systemImage: "rectangle.stack.badge.play.fill"
                            )
                        }
                    }

                    Button {
                        notePlaybackInteraction()
                        toggleIOSVideoFullscreen()
                    } label: {
                        Label(
                            isIOSVideoFullscreen ? "退出全屏" : "进入全屏",
                            systemImage: isIOSVideoFullscreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.14))
                    )
            }
            .foregroundStyle(.white)
        #else
            EmptyView()
        #endif
    }

    private func showsCompactPlaybackControls(for width: CGFloat) -> Bool {
        #if os(macOS)
            false
        #else
            width < 680
        #endif
    }

    #if !os(macOS)
        private func showMobileDanmakuSheet() {
            notePlaybackInteraction()
            mobileDanmakuSheetPresented = true
        }
    #endif

    private func chromeRect(
        in surfaceSize: CGSize,
        videoRect: CGRect,
        isImmersive: Bool
    ) -> CGRect {
        guard isImmersive, videoRect.width > 0, videoRect.height > 0 else {
            return CGRect(origin: .zero, size: surfaceSize)
        }
        return videoRect
    }

    private func danmakuOverlay(
        in viewport: CGSize,
        metrics: DanmakuLayoutMetrics
    ) -> some View {
        DanmakuMetalOverlay(
            renderer: danmaku.renderer,
            timebase: playback.timebase,
            viewport: viewport,
            metrics: metrics
        )
    }

    private func fittedVideoRect(in containerSize: CGSize) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        let aspect = playbackVideoAspect
        guard aspect > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let containerAspect = containerSize.width / containerSize.height
        if aspect > containerAspect {
            let fittedHeight = containerSize.width / aspect
            return CGRect(
                x: 0,
                y: (containerSize.height - fittedHeight) / 2,
                width: containerSize.width,
                height: fittedHeight
            )
        } else {
            let fittedWidth = containerSize.height * aspect
            return CGRect(
                x: (containerSize.width - fittedWidth) / 2,
                y: 0,
                width: fittedWidth,
                height: containerSize.height
            )
        }
    }

    private func trackMenu(
        title: String,
        systemImage: String,
        tracks: [MediaTrackOption],
        selectedID: Int64?,
        includeOffOption: Bool,
        onSelect: @escaping (Int64?) -> Void
    ) -> some View {
        Menu {
            if includeOffOption {
                trackMenuButton(
                    title: "关闭字幕",
                    detail: "",
                    isSelected: selectedID == nil
                ) {
                    onSelect(nil)
                }
            }

            ForEach(tracks) { track in
                trackMenuButton(
                    title: track.title,
                    detail: track.detail,
                    isSelected: selectedID == track.mpvID
                ) {
                    onSelect(track.mpvID)
                }
            }
        } label: {
            MenuChip(title: title, systemImage: systemImage)
                .opacity(tracks.isEmpty && !includeOffOption ? 0.55 : 1)
        }
        .disabled(tracks.isEmpty && !includeOffOption)
    }

    private func trackMenuButton(
        title: String,
        detail: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func chromeButton(
        systemName: String,
        disabled: Bool = false,
        size: CGFloat = 34,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .bold))
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(
                            emphasized
                                ? Palette.accent.opacity(disabled ? 0.18 : 0.92)
                                : .white.opacity(disabled ? 0.08 : 0.14)
                        )
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
    }

    private func playbackTimeText(_ seconds: Double) -> some View {
        Text(timeString(seconds))
            .font(
                .system(
                    size: 13,
                    weight: .semibold,
                    design: .rounded
                )
            )
            .foregroundStyle(.white.opacity(0.88))
    }

    private var playbackDurationText: some View {
        Text(timeString(playback.snapshot.duration))
            .font(
                .system(
                    size: 13,
                    weight: .semibold,
                    design: .rounded
                )
            )
            .foregroundStyle(.white.opacity(0.62))
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private var showsPlaybackChrome: Bool {
        playbackChromeVisible
    }

    private var displayedPlaybackPosition: Double {
        resolvedPlaybackPosition(at: Date())
    }

    private func resolvedPlaybackPosition(at date: Date) -> Double {
        if isScrubbing {
            return scrubPosition
        }
        if let pendingSeekPosition {
            return pendingSeekPosition
        }
        return playback.timebase.resolvedPosition(at: date)
    }

    private var usesImmersivePlaybackLayout: Bool {
        #if os(macOS)
            isVideoFullscreen
        #else
            false
        #endif
    }

    private var usesImmersivePlaybackRoot: Bool {
        #if os(macOS)
            isVideoFullscreen && hasActivePlayback
        #else
            false
        #endif
    }

    private func notePlaybackInteraction() {
        #if os(macOS)
            guard usesImmersivePlaybackLayout, playbackChromeVisible else {
                return
            }
            setPlaybackCursorHidden(false)
            schedulePlaybackChromeAutoHide()
        #else
            guard playbackChromeVisible else { return }
            schedulePlaybackChromeAutoHide()
        #endif
    }

    private func showPlaybackChrome() {
        cancelPlaybackChromeAutoHide()
        withAnimation(.easeInOut(duration: 0.18)) {
            playbackChromeVisible = true
        }
        #if os(macOS)
            setPlaybackCursorHidden(false)
        #endif
    }

    private func hidePlaybackChrome(cancelAutoHide: Bool = true) {
        if cancelAutoHide {
            cancelPlaybackChromeAutoHide()
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            playbackChromeVisible = false
        }
        #if os(macOS)
            setPlaybackCursorHidden(usesImmersivePlaybackLayout)
        #endif
    }

    private func cancelPlaybackChromeAutoHide() {
        playbackChromeAutoHideTask?.cancel()
        playbackChromeAutoHideTask = nil
    }

    private func beginOptimisticSeek(to seconds: Double) {
        let target = clampedSeekPosition(seconds)
        clearPendingSeek(syncTo: target)
        scrubPosition = target
        isScrubbing = false
        pendingSeekPosition = target
        notePlaybackInteraction()
        coordinator.seek(to: target)

        pendingSeekResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            clearPendingSeek(syncTo: playback.snapshot.position)
        }
    }

    private func clearPendingSeek(syncTo position: Double? = nil) {
        pendingSeekResetTask?.cancel()
        pendingSeekResetTask = nil
        pendingSeekPosition = nil
        if let position {
            scrubPosition = position
        }
    }

    private func clampedSeekPosition(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let lowerBound = max(0, seconds)
        guard playback.snapshot.duration > 0 else { return lowerBound }
        return min(playback.snapshot.duration, lowerBound)
    }

    private func handlePlaybackSurfaceSizeChange(_ size: CGSize) {
        guard hasActivePlayback else { return }
        guard size.width > 1, size.height > 1 else { return }

        let previousSize = lastPlaybackSurfaceSize
        let widthChanged =
            abs(size.width - previousSize.width) > 0.5
        let heightChanged =
            abs(size.height - previousSize.height) > 0.5
        guard widthChanged || heightChanged else { return }
        lastPlaybackSurfaceSize = size

        #if os(macOS)
            guard !pendingVideoFullscreenEntry else { return }
            playbackHostRemountTask?.cancel()
            playbackHostRemountTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                playbackHost.remountHost()
                playbackHostRemountTask = nil
            }
        #else
            let widthDelta = abs(size.width - previousSize.width)
            let heightDelta = abs(size.height - previousSize.height)
            let previousLandscape = previousSize.width > previousSize.height
            let currentLandscape = size.width > size.height
            let orientationClassChanged =
                previousSize != .zero && previousLandscape != currentLandscape
            let needsHostRemount =
                !mobileDanmakuSheetPresented
                && (orientationClassChanged || widthDelta > 48
                    || heightDelta > 48)

            if needsHostRemount {
                playbackHostRemountTask?.cancel()
                playbackHostRemountTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    playbackHost.remountHost()
                    showPlaybackChrome()
                    schedulePlaybackChromeAutoHide()
                    playbackHostRemountTask = nil
                }
            } else {
                showPlaybackChrome()
                schedulePlaybackChromeAutoHide()
            }
        #endif
    }

    #if os(macOS)
        private func updatePlaybackChrome(for phase: HoverPhase) {
            switch phase {
            case .active(_):
                showPlaybackChrome()
                if usesImmersivePlaybackLayout, !isScrubbing {
                    schedulePlaybackChromeAutoHide()
                }
            case .ended:
                hidePlaybackChrome()
            }
        }

        private func toggleVideoFullscreen() {
            if isVideoFullscreen || pendingVideoFullscreenEntry {
                dismissVideoFullscreenIfNeeded()
                return
            }

            splitViewVisibilityBeforeVideoFullscreen = splitViewVisibility
            splitViewVisibility = .detailOnly
            playbackChromeVisible = false

            if isWindowFullscreen {
                isVideoFullscreen = true
                return
            }

            pendingVideoFullscreenEntry = true
            videoFullscreenOwnsWindowFullscreen = true
            toggleWindowFullscreen()
        }

        private func dismissVideoFullscreenIfNeeded() {
            guard isVideoFullscreen || pendingVideoFullscreenEntry else {
                return
            }

            isVideoFullscreen = false
            pendingVideoFullscreenEntry = false
            playbackChromeVisible = false
            cancelPlaybackChromeAutoHide()
            setPlaybackCursorHidden(false)
            restoreSplitViewVisibilityAfterVideoFullscreen()

            guard videoFullscreenOwnsWindowFullscreen, isWindowFullscreen else {
                videoFullscreenOwnsWindowFullscreen = false
                return
            }

            videoFullscreenOwnsWindowFullscreen = false
            toggleWindowFullscreen()
        }

        private func restoreSplitViewVisibilityAfterVideoFullscreen() {
            splitViewVisibility =
                splitViewVisibilityBeforeVideoFullscreen ?? .all
            splitViewVisibilityBeforeVideoFullscreen = nil
        }

        private func toggleWindowFullscreen() {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
                return
            }
            window.toggleFullScreen(nil)
        }

        private func schedulePlaybackChromeAutoHide() {
            playbackChromeAutoHideTask?.cancel()
            playbackChromeAutoHideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                guard usesImmersivePlaybackLayout, !isScrubbing else {
                    playbackChromeAutoHideTask = nil
                    return
                }
                hidePlaybackChrome(cancelAutoHide: false)
                playbackChromeAutoHideTask = nil
            }
        }

        private func setPlaybackCursorHidden(_ hidden: Bool) {
            NSCursor.setHiddenUntilMouseMoves(hidden)
        }
    #else
        private func toggleIOSVideoFullscreen() {
            setIOSVideoFullscreen(!isIOSVideoFullscreen)
        }

        private func setIOSVideoFullscreen(_ isFullscreen: Bool) {
            guard isIOSVideoFullscreen != isFullscreen else { return }
            isIOSVideoFullscreen = isFullscreen

            if isFullscreen {
                StarmineiOSOrientationController.enterVideoFullscreen()
            } else {
                StarmineiOSOrientationController.exitVideoFullscreen()
            }

            showPlaybackChrome()
            schedulePlaybackChromeAutoHide()
        }

        private func handlePlaybackSurfaceTap() {
            showPlaybackChrome()
            schedulePlaybackChromeAutoHide()
        }

        private func schedulePlaybackChromeAutoHide() {
            playbackChromeAutoHideTask?.cancel()
            playbackChromeAutoHideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    playbackChromeVisible = false
                }
                playbackChromeAutoHideTask = nil
            }
        }
    #endif
}

private struct PlaybackSurfaceState: Equatable {
    var paused: Bool
    var videoAspect: Double

    init(snapshot: PlaybackSnapshot) {
        paused = snapshot.paused
        videoAspect = snapshot.videoAspect
    }
}
