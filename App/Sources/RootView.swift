import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct RootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var playbackHost = MPVVideoHostBridge()
    @State private var importerPresented = false
    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false
    @State private var pendingSeekPosition: Double?
    @State private var pendingSeekResetTask: Task<Void, Never>?
    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
    @State private var playbackChromeVisible = false
    @State private var playbackChromeAutoHideTask: Task<Void, Never>?
    @State private var workspaceSection: WorkspaceSection = .library
    @State private var jellyfinLibrarySearch = ""
    @State private var showJellyfinConnectForm = false
    @State private var showJellyfinRouteForm = false
    @State private var jellyfinServerURL = ""
    @State private var jellyfinUsername = ""
    @State private var jellyfinPassword = ""
    @State private var jellyfinRouteName = ""
    @State private var jellyfinAdditionalRouteURL = ""
    @State private var jellyfinAdditionalRouteName = ""
#if os(macOS)
    @State private var isWindowFullscreen = false
    @State private var isVideoFullscreen = false
    @State private var pendingVideoFullscreenEntry = false
    @State private var videoFullscreenOwnsWindowFullscreen = false
    @State private var splitViewVisibilityBeforeVideoFullscreen: NavigationSplitViewVisibility?
    @State private var lastPlaybackSurfaceSize: CGSize = .zero
    @State private var playbackHostRemountTask: Task<Void, Never>?
#endif
    
    var body: some View {
        rootContent
            .fileImporter(
                isPresented: $importerPresented,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    model.openVideo(url: url)
                case let .failure(error):
                    model.errorState = AppErrorState(message: error.localizedDescription)
                }
            }
            .alert(item: $model.errorState) { errorState in
                Alert(title: Text("请求失败"), message: Text(errorState.message))
            }
            .onChange(of: model.playback.position) { newValue in
                guard !isScrubbing else { return }
                if let pendingSeekPosition {
                    if abs(newValue - pendingSeekPosition) <= 0.75 {
                        clearPendingSeek(syncTo: newValue)
                    }
                    return
                }
                scrubPosition = newValue
            }
            .onChange(of: model.currentVideoURL) { newValue in
                clearPendingSeek(syncTo: 0)
                if newValue == nil {
#if os(macOS)
                    dismissVideoFullscreenIfNeeded()
#endif
                    hidePlaybackChrome()
                    if model.activeJellyfinAccount != nil {
                        workspaceSection = .library
                    }
                } else {
                    workspaceSection = .player
                }
            }
            .onChange(of: model.selectedJellyfinAccountID) { newValue in
                guard newValue != nil, model.currentVideoURL == nil else { return }
                workspaceSection = .library
            }
            .onChange(of: model.selectedJellyfinLibraryID) { _ in
                jellyfinLibrarySearch = ""
            }
            .onDisappear {
                cancelPlaybackChromeAutoHide()
                pendingSeekResetTask?.cancel()
                pendingSeekResetTask = nil
#if os(macOS)
                playbackHostRemountTask?.cancel()
                playbackHostRemountTask = nil
                setPlaybackCursorHidden(false)
#endif
            }
#if os(macOS)
            .modifier(WindowToolbarFullscreenBehavior(isVideoFullscreen: isVideoFullscreen))
            .background(
                PlaybackShortcutMonitor(
                    onTogglePause: {
                        guard model.currentVideoURL != nil else { return }
                        model.togglePause()
                    },
                    onToggleFullscreen: {
                        guard model.currentVideoURL != nil else { return }
                        toggleVideoFullscreen()
                    }
                )
            )
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
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
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
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
                } else if isVideoFullscreen || videoFullscreenOwnsWindowFullscreen {
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
        splitViewContent
#endif
    }
    
    private var splitViewContent: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 290, ideal: 320, max: 360)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
    }
    
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    importerPresented = true
                } label: {
                    Label("打开视频", systemImage: "play.rectangle.fill")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [Palette.accent, Palette.accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("当前文件")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink.opacity(0.55))
                    Text(model.currentVideoTitle)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                }
                .cardStyle()
                
                jellyfinPanel

                if let account = model.activeJellyfinAccount {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            workspaceSection = .library
                        }
                    } label: {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Palette.accent.opacity(0.88), Palette.accentDeep.opacity(0.92)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 62, height: 78)
                                .overlay {
                                    Image(systemName: "film.stack.fill")
                                        .font(.system(size: 24, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("媒体库节目")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                    .foregroundStyle(Palette.ink)
                                Text(model.selectedJellyfinLibrary?.name ?? "Jellyfin")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Palette.ink.opacity(0.62))
                                    .lineLimit(2)
                                Text(account.displayTitle)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Palette.ink.opacity(0.46))
                                    .lineLimit(1)
                            }
                            
                            Spacer(minLength: 10)
                            
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Palette.accentDeep)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .cardStyle()
                }
                
                if model.currentVideoURL != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("播放信息", systemImage: "gauge.with.needle")
                        statRow(title: "状态", value: model.playback.paused ? "暂停" : "播放中")
                        statRow(title: "位置", value: timeString(displayedPlaybackPosition))
                        statRow(title: "时长", value: timeString(model.playback.duration))
                        statRow(title: "音轨", value: model.selectedAudioTrack?.title ?? "无")
                        statRow(title: "字幕", value: model.selectedSubtitleTrack?.title ?? "关闭")
                    }
                    .cardStyle()
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Palette.ink.opacity(0.45))
                        TextField("搜索番剧", text: $model.searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .onSubmit {
                                Task { await model.searchAndAutoloadDanmaku() }
                            }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Palette.surface)
                    )
                    
                    Button {
                        Task { await model.searchAndAutoloadDanmaku() }
                    } label: {
                        HStack {
                            if model.isSearching {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            } else {
                                Image(systemName: "magnifyingglass.circle.fill")
                            }
                            Text("搜索弹幕")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accentDeep)
                }
                .cardStyle()
                
                if !model.searchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("弹幕匹配", systemImage: "rectangle.stack.fill")
                        ForEach(model.searchResults) { anime in
                            Button {
                                model.pickAnime(anime)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(anime.title)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Palette.ink)
                                        .lineLimit(2)
                                    if !anime.typeDescription.isEmpty || anime.episodeCount != nil {
                                        Text([anime.typeDescription, anime.episodeCount.map { "\($0) 集" }].compactMap { $0 }.joined(separator: " · "))
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundStyle(Palette.ink.opacity(0.55))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(model.selectedAnimeID == anime.id ? Palette.selection : Palette.surface)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .cardStyle()
                }
                
                if !model.episodes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("弹幕剧集", systemImage: "text.badge.plus")
                        ForEach(model.episodes) { episode in
                            Button {
                                model.pickEpisode(episode)
                            } label: {
                                Text(episode.displayTitle)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(Palette.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(model.selectedEpisodeID == episode.id ? Palette.selection : Palette.surface)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .cardStyle()
                }
            }
            .padding(20)
        }
        .background(Palette.sidebarBackground.ignoresSafeArea())
        .navigationTitle("Starmine")
    }
    
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
                    
                    if workspaceSection == .library {
                        mediaLibraryWorkspace
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    } else {
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
                        model.danmakuEnabled.toggle()
                    } label: {
                        Image(systemName: model.danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                    }
                    
#if os(macOS)
                    Button {
                        toggleVideoFullscreen()
                    } label: {
                        Image(systemName: isVideoFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(model.currentVideoURL == nil)
#endif
                }
            }
        }
    }
    
    @ViewBuilder
    private var playbackWorkspace: some View {
        if model.currentVideoURL == nil {
            placeholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                playbackStage(in: proxy.size, isImmersive: usesImmersivePlaybackLayout)
            }
        }
    }
    
    private func playbackStage(in containerSize: CGSize, isImmersive: Bool) -> some View {
        let outerPadding: CGFloat = isImmersive ? 0 : 24
        let cornerRadius: CGFloat = isImmersive ? 0 : 30
        let surfaceSize = CGSize(
            width: max(0, containerSize.width - outerPadding * 2),
            height: max(0, containerSize.height - outerPadding * 2)
        )
        let videoRect = fittedVideoRect(in: surfaceSize)
        
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black)
            
            MPVVideoHostRepresentable(player: model.player, host: playbackHost)
                .id(playbackHost.mountToken)
                .frame(width: surfaceSize.width, height: surfaceSize.height)
                .background(Color.black)
                .allowsHitTesting(false)
            
            if model.danmakuEnabled, videoRect.width > 0, videoRect.height > 0 {
                danmakuOverlay(in: videoRect.size, metrics: .playbackChrome)
                    .frame(width: videoRect.width, height: videoRect.height)
                    .offset(
                        x: videoRect.origin.x,
                        y: videoRect.origin.y
                    )
                    .clipped()
                    .allowsHitTesting(false)
            }
            
            playbackChromeOverlay(in: surfaceSize, videoRect: videoRect, isImmersive: isImmersive)
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height)
        .contentShape(Rectangle())
#if os(macOS)
        .onAppear {
            handlePlaybackSurfaceSizeChange(surfaceSize)
        }
        .onChange(of: surfaceSize) { newValue in
            handlePlaybackSurfaceSizeChange(newValue)
        }
        .onContinuousHover { phase in
            updatePlaybackChrome(for: phase)
        }
#endif
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                .opacity(isImmersive ? 0 : 1)
        }
        .shadow(color: .black.opacity(isImmersive ? 0 : 0.16), radius: isImmersive ? 0 : 24, x: 0, y: isImmersive ? 0 : 10)
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
                    .fill(LinearGradient(colors: [Palette.accent.opacity(0.18), Palette.selection], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 200, height: 200)
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(Palette.accentDeep)
            }
            
            Button {
                importerPresented = true
            } label: {
                Text("打开视频")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accentDeep)
            
            if model.activeJellyfinAccount != nil {
                Button {
                    workspaceSection = .library
                } label: {
                    Label("进入媒体库", systemImage: "rectangle.stack.fill")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
            }
        }
    }
    
    private var workspaceHeader: some View {
        HStack(spacing: 18) {
            if workspaceSection == .library, model.selectedJellyfinItem != nil {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        model.selectedJellyfinItemID = nil
                    }
                } label: {
                    Image(systemName: "chevron.backward.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Palette.accentDeep, Palette.accent.opacity(0.18))
                }
                .buttonStyle(.plain)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(workspaceSection == .library ? "媒体库节目" : "播放器")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                if !workspaceSummaryText.isEmpty {
                    Text(workspaceSummaryText)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.ink.opacity(0.58))
                        .lineLimit(2)
                }
            }
            
            Spacer(minLength: 12)
            
            Picker("", selection: $workspaceSection) {
                Text("媒体库").tag(WorkspaceSection.library)
                Text("播放器").tag(WorkspaceSection.player)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            
            if let account = model.activeJellyfinAccount {
                headerCapsule(title: account.username, systemImage: "person.crop.circle.fill")
            }
            
            if let route = model.activeJellyfinRoute {
                headerCapsule(title: route.name, systemImage: "point.3.connected.trianglepath.dotted")
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
        case .library:
            if let item = model.selectedJellyfinItem {
                return item.metaLine.isEmpty ? item.name : "\(item.name) · \(item.metaLine)"
            }
            if let library = model.selectedJellyfinLibrary {
                return "\(library.name) · \(library.subtitle)"
            }
            if let account = model.activeJellyfinAccount {
                return account.displayTitle
            }
            return ""
        case .player:
            if model.currentVideoURL != nil {
                return model.currentVideoTitle
            }
            return ""
        }
    }
    
    @ViewBuilder
    private var mediaLibraryWorkspace: some View {
        if model.activeJellyfinAccount == nil {
            VStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Palette.selection, Palette.accent.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 156, height: 196)
                    .overlay {
                        Image(systemName: "server.rack")
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                
                Text("Jellyfin")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text("未连接")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.52))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .panelStyle(cornerRadius: 30)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    if let item = model.selectedJellyfinItem {
                        selectedItemShowcase
                        if item.kind.isSeriesLike {
                            libraryInspectorPanel
                        }
                    } else {
                        libraryShelf
                        libraryExplorerContent
                    }
                }
            }
        }
    }
    
    private var selectedItemShowcase: some View {
        let selectedItem = model.selectedJellyfinItem
        let title = selectedItem?.name ?? "Jellyfin"
        let subtitle = selectedItem.flatMap { item in
            [item.kind.displayName, item.productionYear.map(String.init)]
                .compactMap { $0 }
                .joined(separator: " · ")
                .nilIfEmpty
        } ?? ""
        let summary = selectedItem?.overview?.nilIfEmpty
        let rating = selectedItem?.formattedCommunityRating
        let posterURL = selectedItem.flatMap { model.jellyfinPosterURL(for: $0, width: 420, height: 630) }
        let backdropURL = selectedItem.flatMap { model.jellyfinBackdropURL(for: $0, width: 1600, height: 860) }
        
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.23, green: 0.18, blue: 0.16),
                            Color(red: 0.35, green: 0.22, blue: 0.16),
                            Color(red: 0.67, green: 0.28, blue: 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            if let backdropURL, selectedItem != nil {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    JellyfinArtworkView(
                        url: backdropURL,
                        placeholderSystemName: "sparkles.tv.fill",
                        cornerRadius: 30
                    )
                    .frame(width: 520)
                    .mask(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.4), .black],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(0.72)
                }
            }
            
            LinearGradient(
                colors: [Color.black.opacity(0.06), Color.black.opacity(0.24), Color.black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            
            HStack(alignment: .bottom, spacing: 24) {
                JellyfinArtworkView(
                    url: posterURL,
                    placeholderSystemName: selectedItem?.kind.isSeriesLike == true ? "tv.inset.filled" : "film.fill",
                    cornerRadius: 24
                )
                .frame(width: 148, height: 214)
                .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 8)
                
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        if let selectedItem {
                            pill(model.selectedJellyfinLibrary?.name ?? selectedItem.kind.displayName)
                            pill(selectedItem.kind.displayName)
                        }
                        if model.isLoadingJellyfin {
                            ProgressView()
                                .tint(.white)
                        }
                    }
                    
                    Text(title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                            .monospacedDigit()
                    }
                    
                    HStack(spacing: 10) {
                        if let rating {
                            statPill("评分 \(rating)", emphasized: true)
                                .monospacedDigit()
                        }
                        if let year = selectedItem?.productionYear {
                            statPill(String(year))
                        }
                        if let kind = selectedItem?.kind {
                            statPill(kind.displayName)
                        }
                    }
                    
                    if let summary {
                        Text(summary)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineSpacing(3)
                            .lineLimit(4)
                    }
                    
                    HStack(spacing: 12) {
                        if let selectedItem, selectedItem.kind.isPlayable {
                            Button(selectedItem.resumePositionSeconds == nil ? "立即播放" : "继续播放") {
                                workspaceSection = .player
                                model.playJellyfinMediaItem(selectedItem)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.accent)
                        }
                        
                        Button {
                            Task { await model.refreshJellyfinLibrary() }
                        } label: {
                            Label("刷新媒体库", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        
                        if model.currentVideoURL != nil {
                            Button {
                                workspaceSection = .player
                            } label: {
                                Label("切到播放器", systemImage: "play.rectangle.fill")
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding(28)
        }
        .frame(minHeight: 232)
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 20, x: 0, y: 12)
    }
    
    private var libraryShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("媒体库", systemImage: "rectangle.stack.badge.play")
            
            if model.isLoadingJellyfin, model.jellyfinLibraries.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("载入中")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.ink.opacity(0.68))
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelStyle()
            } else if model.jellyfinLibraries.isEmpty {
                Text("没有媒体库")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.62))
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelStyle()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(model.jellyfinLibraries) { library in
                            Button {
                                model.selectJellyfinLibrary(library)
                            } label: {
                                HStack(spacing: 14) {
                                    JellyfinArtworkView(
                                        url: model.jellyfinLibraryImageURL(library, width: 240, height: 360),
                                        placeholderSystemName: "square.stack.3d.up.fill",
                                        cornerRadius: 22
                                    )
                                    .frame(width: 88, height: 124)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(library.name)
                                            .font(.system(size: 16, weight: .bold, design: .rounded))
                                            .foregroundStyle(Palette.ink)
                                            .lineLimit(2)
                                        Text(library.subtitle)
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundStyle(Palette.ink.opacity(0.6))
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer(minLength: 0)
                                    
                                    if model.selectedJellyfinLibraryID == library.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundStyle(Palette.accentDeep)
                                    }
                                }
                                .padding(14)
                                .frame(width: 286, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                                        .fill(model.selectedJellyfinLibraryID == library.id ? Palette.selection : Color.white.opacity(0.86))
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                                        .strokeBorder(
                                            model.selectedJellyfinLibraryID == library.id ? Palette.accent.opacity(0.34) : .white.opacity(0.65),
                                            lineWidth: 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
    
    private var libraryExplorerContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedJellyfinLibrary?.name ?? "媒体库")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                    Text("当前媒体库共 \(filteredJellyfinItems.count) 个节目")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.ink.opacity(0.58))
                }
                
                Spacer()
                
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Palette.ink.opacity(0.45))
                    TextField("筛选当前媒体库", text: $jellyfinLibrarySearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                    
                    if !jellyfinLibrarySearch.isEmpty {
                        Button {
                            jellyfinLibrarySearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Palette.ink.opacity(0.38))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: 280)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.86))
                )
            }
            
            ViewThatFits(in: .horizontal) {
                libraryGridPanel
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    private var libraryGridPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("节目封面", systemImage: "square.grid.3x3.fill")
            
            if model.selectedJellyfinLibrary == nil {
                Text("未选择媒体库")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.62))
            } else if model.isLoadingJellyfin, model.jellyfinItems.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("载入中")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.ink.opacity(0.68))
                }
            } else if filteredJellyfinItems.isEmpty {
                Text(jellyfinLibrarySearch.isEmpty ? "没有节目" : "没有匹配结果")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.62))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 18)], spacing: 18) {
                    ForEach(filteredJellyfinItems) { item in
                        Button {
                            model.selectJellyfinItem(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                ZStack(alignment: .bottomLeading) {
                                    JellyfinArtworkView(
                                        url: model.jellyfinPosterURL(for: item, width: 420, height: 630),
                                        placeholderSystemName: item.kind.isSeriesLike ? "tv.inset.filled" : "film.fill",
                                        cornerRadius: 24
                                    )
                                    .frame(height: 246)
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Spacer()
                                            Text(item.kind.displayName)
                                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(
                                                    Capsule(style: .continuous)
                                                        .fill(Color.black.opacity(0.48))
                                                )
                                        }
                                        
                                        Spacer(minLength: 0)
                                        
                                        if progressFraction(position: item.resumePositionSeconds, durationTicks: item.runTimeTicks) > 0 {
                                            Capsule(style: .continuous)
                                                .fill(Color.white.opacity(0.18))
                                                .frame(height: 4)
                                                .overlay(alignment: .leading) {
                                                    Capsule(style: .continuous)
                                                        .fill(Palette.accent)
                                                        .frame(width: max(8, 176 * progressFraction(position: item.resumePositionSeconds, durationTicks: item.runTimeTicks)), height: 4)
                                                }
                                        }
                                    }
                                    .padding(12)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundStyle(Palette.ink)
                                        .lineLimit(2)
                                    if let metaLine = item.metaLine.nilIfEmpty {
                                        Text(metaLine)
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundStyle(Palette.ink.opacity(0.58))
                                            .lineLimit(2)
                                            .monospacedDigit()
                                    }
                                    if let overview = item.overview?.nilIfEmpty {
                                        Text(overview)
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundStyle(Palette.ink.opacity(0.46))
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .fill(model.selectedJellyfinItemID == item.id ? Palette.selection : Color.white.opacity(0.88))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .strokeBorder(
                                        model.selectedJellyfinItemID == item.id ? Palette.accent.opacity(0.34) : .white.opacity(0.72),
                                        lineWidth: 1
                                    )
                            }
                            .shadow(color: .black.opacity(model.selectedJellyfinItemID == item.id ? 0.09 : 0.04), radius: 14, x: 0, y: 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(20)
        .panelStyle(cornerRadius: 30)
    }
    
    private var libraryInspectorPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let item = model.selectedJellyfinItem {
                if item.kind.isSeriesLike {
                    if !model.jellyfinSeasons.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader("季度", systemImage: "square.grid.2x2.fill")
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(model.jellyfinSeasons) { season in
                                        Button {
                                            model.selectJellyfinSeason(season)
                                        } label: {
                                            Text(season.displayTitle)
                                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                .foregroundStyle(model.selectedJellyfinSeasonID == season.id ? .white : Palette.ink)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 10)
                                                .background(
                                                    Capsule(style: .continuous)
                                                        .fill(model.selectedJellyfinSeasonID == season.id ? Palette.accentDeep : Color.white.opacity(0.82))
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    
                    Divider()
                        .overlay(Palette.ink.opacity(0.08))
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            sectionHeader("剧集", systemImage: "play.rectangle.on.rectangle")
                            Spacer()
                            Text("\(filteredJellyfinEpisodes.count) 集")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Palette.ink.opacity(0.52))
                        }
                        
                        if model.isLoadingJellyfin, model.jellyfinEpisodes.isEmpty {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("载入中")
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(Palette.ink.opacity(0.68))
                            }
                        } else if filteredJellyfinEpisodes.isEmpty {
                            Text(jellyfinLibrarySearch.isEmpty ? "没有剧集" : "没有匹配结果")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Palette.ink.opacity(0.58))
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredJellyfinEpisodes) { episode in
                                    Button {
                                        workspaceSection = .player
                                        model.playJellyfinEpisode(episode)
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            JellyfinArtworkView(
                                                url: model.jellyfinEpisodeThumbnailURL(episode, width: 320, height: 180),
                                                placeholderSystemName: "play.tv.fill",
                                                cornerRadius: 18
                                            )
                                            .frame(width: 112, height: 63)
                                            
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(episode.displayTitle)
                                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                                    .foregroundStyle(Palette.ink)
                                                    .lineLimit(2)
                                                if let runtime = runtimeText(fromTicks: episode.runTimeTicks).nilIfEmpty {
                                                    Text(runtime)
                                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                        .foregroundStyle(Palette.ink.opacity(0.58))
                                                }
                                                if let overview = episode.overview?.nilIfEmpty {
                                                    Text(overview)
                                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                                        .foregroundStyle(Palette.ink.opacity(0.46))
                                                        .lineLimit(2)
                                                }
                                            }
                                            
                                            Spacer(minLength: 0)
                                            
                                            Image(systemName: model.selectedJellyfinEpisodeID == episode.id ? "speaker.wave.2.circle.fill" : "play.circle.fill")
                                                .font(.system(size: 24, weight: .semibold))
                                                .foregroundStyle(model.selectedJellyfinEpisodeID == episode.id ? Palette.accentDeep : Palette.accent)
                                        }
                                        .padding(12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                                .fill(model.selectedJellyfinEpisodeID == episode.id ? Palette.selection : Color.white.opacity(0.74))
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            } else {
                sectionHeader("节目详情", systemImage: "rectangle.stack.fill")
                
                if let library = model.selectedJellyfinLibrary {
                    HStack(alignment: .top, spacing: 16) {
                        JellyfinArtworkView(
                            url: model.jellyfinLibraryImageURL(library, width: 360, height: 540),
                            placeholderSystemName: "square.stack.3d.up.fill",
                            cornerRadius: 24
                        )
                        .frame(width: 116, height: 168)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text(library.name)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(Palette.ink)
                            Text(library.subtitle)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Palette.ink.opacity(0.56))
                        }
                    }
                } else {
                    Text("未选择节目")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.ink.opacity(0.62))
                }
            }
        }
        .padding(20)
        .panelStyle(cornerRadius: 30)
    }
    
    private var filteredJellyfinItems: [JellyfinMediaItem] {
        let keyword = normalizedLibrarySearch
        guard !keyword.isEmpty else { return model.jellyfinItems }
        return model.jellyfinItems.filter { item in
            [item.name, item.originalTitle, item.overview]
                .compactMap { $0?.foldedForSearch() }
                .contains(where: { $0.contains(keyword) })
        }
    }
    
    private var filteredJellyfinEpisodes: [JellyfinEpisode] {
        let keyword = normalizedLibrarySearch
        guard !keyword.isEmpty else { return model.jellyfinEpisodes }
        return model.jellyfinEpisodes.filter { episode in
            [episode.name, episode.displayTitle, episode.overview]
                .compactMap { $0?.foldedForSearch() }
                .contains(where: { $0.contains(keyword) })
        }
    }
    
    private var normalizedLibrarySearch: String {
        jellyfinLibrarySearch.foldedForSearch()
    }
    
    private func headerCapsule(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(Palette.ink.opacity(0.82))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.8))
        )
    }
    
    private func statPill(_ text: String, emphasized: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(emphasized ? 0.98 : 0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(emphasized ? Palette.accent.opacity(0.88) : .white.opacity(0.14))
            )
    }
    
    private func runtimeText(fromTicks ticks: Double?) -> String {
        guard let ticks, ticks > 0 else { return "" }
        let totalMinutes = Int((ticks / 10_000_000.0 / 60.0).rounded())
        if totalMinutes >= 60 {
            return "\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分钟"
        }
        return "\(totalMinutes) 分钟"
    }
    
    private func progressFraction(position: Double?, durationTicks: Double?) -> CGFloat {
        guard let position, let durationTicks else { return 0 }
        let duration = durationTicks / 10_000_000.0
        guard duration > 0 else { return 0 }
        return CGFloat(max(0, min(1, position / duration)))
    }
    
    private var jellyfinPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                sectionHeader("Jellyfin", systemImage: "server.rack")
                Spacer()
                if model.isLoadingJellyfin || model.isConnectingJellyfin {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }
            
            if let account = model.activeJellyfinAccount {
                Menu {
                    ForEach(model.jellyfinAccounts) { candidate in
                        Button {
                            model.switchJellyfinAccount(candidate.id)
                        } label: {
                            HStack {
                                Text(candidate.displayTitle)
                                Spacer()
                                if candidate.id == model.selectedJellyfinAccountID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    headerCapsule(title: account.displayTitle, systemImage: "person.crop.circle.fill")
                }
                
                Menu {
                    ForEach(account.enabledRoutes) { route in
                        Button {
                            model.switchJellyfinRoute(route.id)
                        } label: {
                            HStack {
                                Text(route.name)
                                Spacer()
                                if route.id == model.activeJellyfinRoute?.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    headerCapsule(title: model.activeJellyfinRoute?.name ?? "自动线路", systemImage: "point.3.connected.trianglepath.dotted")
                }
                
                statRow(title: "服务器", value: account.serverName)
                statRow(title: "用户", value: account.username)
            } else {
                Text("未连接")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.62))
            }
            
            HStack(spacing: 10) {
                Button(model.jellyfinAccounts.isEmpty ? "连接账号" : (showJellyfinConnectForm ? "收起账号表单" : "新增账号")) {
                    showJellyfinConnectForm.toggle()
                }
                .buttonStyle(.bordered)
                
                Button(showJellyfinRouteForm ? "收起线路表单" : "新增线路") {
                    showJellyfinRouteForm.toggle()
                }
                .buttonStyle(.bordered)
                .disabled(model.activeJellyfinAccount == nil)
                
                Button {
                    Task { await model.refreshJellyfinLibrary() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.activeJellyfinAccount == nil)
                
                Button(role: .destructive) {
                    model.removeSelectedJellyfinAccount()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(model.activeJellyfinAccount == nil)
            }
            
            if showJellyfinConnectForm || model.jellyfinAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("服务器地址，如 http://192.168.1.10:8096", text: $jellyfinServerURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("用户名", text: $jellyfinUsername)
                        .textFieldStyle(.roundedBorder)
                    SecureField("密码", text: $jellyfinPassword)
                        .textFieldStyle(.roundedBorder)
                    TextField("线路备注，可选", text: $jellyfinRouteName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let serverURL = jellyfinServerURL
                        let username = jellyfinUsername
                        let password = jellyfinPassword
                        let routeName = jellyfinRouteName
                        Task {
                            let success = await model.connectJellyfin(
                                serverURL: serverURL,
                                username: username,
                                password: password,
                                routeName: routeName
                            )
                            if success {
                                jellyfinServerURL = ""
                                jellyfinUsername = ""
                                jellyfinPassword = ""
                                jellyfinRouteName = ""
                                showJellyfinConnectForm = false
                                workspaceSection = .library
                            }
                        }
                    } label: {
                        Text("连接 Jellyfin")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accentDeep)
                }
            }
            
            if showJellyfinRouteForm, model.activeJellyfinAccount != nil {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("新线路地址", text: $jellyfinAdditionalRouteURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("线路备注，可选", text: $jellyfinAdditionalRouteName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let routeURL = jellyfinAdditionalRouteURL
                        let routeName = jellyfinAdditionalRouteName
                        Task {
                            let success = await model.addJellyfinRoute(
                                serverURL: routeURL,
                                routeName: routeName
                            )
                            if success {
                                jellyfinAdditionalRouteURL = ""
                                jellyfinAdditionalRouteName = ""
                                showJellyfinRouteForm = false
                            }
                        }
                    } label: {
                        Text("添加同服线路")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .cardStyle()
    }
    
    private var topOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.currentVideoTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
            
            HStack(spacing: 8) {
                if let selectedAnime = model.selectedAnime {
                    pill(selectedAnime.title)
                }
                if !model.currentEpisodeLabel.isEmpty {
                    pill(model.currentEpisodeLabel)
                }
                if model.isPlayingRemote, let route = model.activeJellyfinRoute?.name {
                    pill(route)
                }
                if let audio = model.selectedAudioTrack {
                    pill(audio.title)
                }
                if let subtitle = model.selectedSubtitleTrack {
                    pill(subtitle.title)
                }
                if model.isLoadingDanmaku {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            LinearGradient(colors: [Color.black.opacity(0.84), Color.black.opacity(0.0)], startPoint: .top, endPoint: .bottom)
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
    private func playbackChromeOverlay(in surfaceSize: CGSize, videoRect: CGRect, isImmersive: Bool) -> some View {
        let chromeRect = chromeRect(in: surfaceSize, videoRect: videoRect, isImmersive: isImmersive)
        
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
        VStack(spacing: 14) {
            PlaybackSeekBar(
                duration: model.playback.duration,
                position: displayedPlaybackPosition,
                bufferedTint: .white,
                onScrubStart: {
                    clearPendingSeek(syncTo: displayedPlaybackPosition)
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
            
            HStack(spacing: 14) {
                chromeButton(systemName: "backward.end.fill", disabled: !model.canPlayPreviousEpisode) {
                    notePlaybackInteraction()
                    model.playPreviousEpisode()
                }
                chromeButton(systemName: model.playback.paused ? "play.fill" : "pause.fill") {
                    notePlaybackInteraction()
                    model.togglePause()
                }
                chromeButton(systemName: "forward.end.fill", disabled: !model.canPlayNextEpisode) {
                    notePlaybackInteraction()
                    model.playNextEpisode()
                }
                chromeButton(systemName: "gobackward.10") {
                    beginOptimisticSeek(to: displayedPlaybackPosition - 10)
                }
                chromeButton(systemName: "goforward.10") {
                    beginOptimisticSeek(to: displayedPlaybackPosition + 10)
                }
                
                Text(timeString(displayedPlaybackPosition))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(width: max(24, width * 0.05), height: 4)
                
                Text(timeString(model.playback.duration))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                
                Spacer(minLength: 12)
                
                trackMenu(
                    title: model.selectedAudioTrack?.title ?? "音轨",
                    systemImage: "music.note",
                    tracks: model.audioTracks,
                    selectedID: model.selectedAudioTrackID,
                    includeOffOption: false
                ) { id in
                    if let id {
                        notePlaybackInteraction()
                        model.selectAudioTrack(id: id)
                    }
                }
                
                trackMenu(
                    title: model.selectedSubtitleTrack?.title ?? "字幕关闭",
                    systemImage: "captions.bubble",
                    tracks: model.subtitleTracks,
                    selectedID: model.selectedSubtitleTrackID,
                    includeOffOption: true
                ) { id in
                    notePlaybackInteraction()
                    model.selectSubtitleTrack(id: id)
                }
                
                chromeButton(systemName: model.danmakuEnabled ? "text.bubble.fill" : "text.bubble") {
                    notePlaybackInteraction()
                    model.danmakuEnabled.toggle()
                }
                
#if os(macOS)
                chromeButton(systemName: isVideoFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    toggleVideoFullscreen()
                }
#endif
                
                chromeButton(systemName: "folder") {
                    notePlaybackInteraction()
                    importerPresented = true
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black.opacity(0.74))
        )
        .padding(18)
    }
    
    private func chromeRect(in surfaceSize: CGSize, videoRect: CGRect, isImmersive: Bool) -> CGRect {
        guard isImmersive, videoRect.width > 0, videoRect.height > 0 else {
            return CGRect(origin: .zero, size: surfaceSize)
        }
        return videoRect
    }
    
    private func danmakuOverlay(in viewport: CGSize, metrics: DanmakuLayoutMetrics) -> some View {
        ZStack {
            ForEach(model.danmakuStore.activeItems) { item in
                Text(item.comment.text)
                    .font(.system(size: item.fontSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(item.comment.color.swiftUI)
                    .shadow(color: .black.opacity(0.92), radius: 4, x: 0, y: 1)
                    .lineLimit(1)
                    .position(model.danmakuStore.point(for: item, playbackTime: model.playback.position, viewportSize: viewport, metrics: metrics))
            }
        }
        .onAppear {
            model.danmakuStore.sync(playbackTime: model.playback.position, viewportSize: viewport, metrics: metrics)
        }
        .onChange(of: model.playback.position) { newValue in
            model.danmakuStore.sync(playbackTime: newValue, viewportSize: viewport, metrics: metrics)
        }
        .onChange(of: viewport) { newValue in
            model.danmakuStore.sync(playbackTime: model.playback.position, viewportSize: newValue, metrics: metrics)
        }
    }
    
    private func fittedVideoRect(in containerSize: CGSize) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        
        let aspect = model.playback.videoAspect
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
                trackMenuButton(title: "关闭字幕", detail: "", isSelected: selectedID == nil) {
                    onSelect(nil)
                }
            }
            
            ForEach(tracks) { track in
                trackMenuButton(title: track.title, detail: track.detail, isSelected: selectedID == track.mpvID) {
                    onSelect(track.mpvID)
                }
            }
        } label: {
            menuChip(title: title, systemImage: systemImage)
                .opacity(tracks.isEmpty && !includeOffOption ? 0.55 : 1)
        }
        .disabled(tracks.isEmpty && !includeOffOption)
    }
    
    private func trackMenuButton(title: String, detail: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
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
    
    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(Palette.ink.opacity(0.65))
    }
    
    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.56))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
    }
    
    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.14))
            )
    }
    
    private func menuChip(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 180)
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(0.14))
        )
    }
    
    private func chromeButton(systemName: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(.white.opacity(disabled ? 0.08 : 0.14))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
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
        if isScrubbing {
            return scrubPosition
        }
        if let pendingSeekPosition {
            return pendingSeekPosition
        }
        return model.playback.position
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
        isVideoFullscreen && model.currentVideoURL != nil
#else
        false
#endif
    }
    
    private func notePlaybackInteraction() {
#if os(macOS)
        guard usesImmersivePlaybackLayout, playbackChromeVisible else { return }
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
        model.seek(to: target)
        
        pendingSeekResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            clearPendingSeek(syncTo: model.playback.position)
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
        guard model.playback.duration > 0 else { return lowerBound }
        return min(model.playback.duration, lowerBound)
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
        guard isVideoFullscreen || pendingVideoFullscreenEntry else { return }
        
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
        splitViewVisibility = splitViewVisibilityBeforeVideoFullscreen ?? .all
        splitViewVisibilityBeforeVideoFullscreen = nil
    }
    
    private func toggleWindowFullscreen() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        window.toggleFullScreen(nil)
    }
    
    private func handlePlaybackSurfaceSizeChange(_ size: CGSize) {
        guard model.currentVideoURL != nil else { return }
        guard size.width > 1, size.height > 1 else { return }
        
        let widthChanged = abs(size.width - lastPlaybackSurfaceSize.width) > 0.5
        let heightChanged = abs(size.height - lastPlaybackSurfaceSize.height) > 0.5
        guard widthChanged || heightChanged else { return }
        lastPlaybackSurfaceSize = size
        
        guard !pendingVideoFullscreenEntry else { return }
        
        playbackHostRemountTask?.cancel()
        playbackHostRemountTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            playbackHost.remountHost()
            playbackHostRemountTask = nil
        }
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

private enum WorkspaceSection {
    case library
    case player
}

private enum Palette {
    static let accent = Color(red: 0.94, green: 0.38, blue: 0.17)
    static let accentDeep = Color(red: 0.79, green: 0.23, blue: 0.08)
    static let canvas = Color(red: 0.95, green: 0.93, blue: 0.89)
    static let sidebarBackground = Color(red: 0.92, green: 0.90, blue: 0.86)
    static let surface = Color.white.opacity(0.82)
    static let selection = Color(red: 1.0, green: 0.84, blue: 0.78)
    static let ink = Color(red: 0.14, green: 0.13, blue: 0.12)
}

private struct JellyfinArtworkView: View {
    let url: URL?
    let placeholderSystemName: String
    let cornerRadius: CGFloat
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Palette.selection.opacity(0.95), Palette.accent.opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            if let url {
                Color.clear
                    .overlay {
                        AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.18))) { phase in
                            switch phase {
                            case let .success(image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            case .failure:
                                placeholder
                            case .empty:
                                placeholder
                            @unknown default:
                                placeholder
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
    
    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Palette.selection, Palette.accent.opacity(0.74)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: placeholderSystemName)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}

private struct PlaybackSeekBar: View {
    let duration: Double
    let position: Double
    let bufferedTint: Color
    let onScrubStart: () -> Void
    let onScrubChange: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    
    var body: some View {
        GeometryReader { proxy in
            let progress = normalizedProgress
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.16))
                    .frame(height: 8)
                
                Capsule(style: .continuous)
                    .fill(bufferedTint.opacity(0.9))
                    .frame(width: proxy.size.width * progress, height: 8)
                
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    .offset(x: max(0, min(proxy.size.width - 16, proxy.size.width * progress - 8)))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrubStart()
                        onScrubChange(seconds(for: value.location.x, width: proxy.size.width))
                    }
                    .onEnded { value in
                        onScrubEnd(seconds(for: value.location.x, width: proxy.size.width))
                    }
            )
        }
        .frame(height: 20)
    }
    
    private var normalizedProgress: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(max(0, min(1, position / duration)))
    }
    
    private func seconds(for x: CGFloat, width: CGFloat) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        let progress = max(0, min(1, x / width))
        return duration * progress
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Palette.surface)
            )
    }
    
    func panelStyle(cornerRadius: CGFloat = 24) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.82))
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.72), lineWidth: 1)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
    
    func foldedForSearch() -> String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

#if os(macOS)
private struct WindowToolbarFullscreenBehavior: ViewModifier {
    let isVideoFullscreen: Bool
    
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowToolbarFullScreenVisibility(isVideoFullscreen ? .onHover : .visible)
        } else {
            content
        }
    }
}

private struct PlaybackShortcutMonitor: NSViewRepresentable {
    let onTogglePause: () -> Void
    let onToggleFullscreen: () -> Void
    
    func makeNSView(context: Context) -> PlaybackShortcutMonitorView {
        let view = PlaybackShortcutMonitorView()
        view.onTogglePause = onTogglePause
        view.onToggleFullscreen = onToggleFullscreen
        return view
    }
    
    func updateNSView(_ nsView: PlaybackShortcutMonitorView, context: Context) {
        nsView.onTogglePause = onTogglePause
        nsView.onToggleFullscreen = onToggleFullscreen
    }
}

private final class PlaybackShortcutMonitorView: NSView {
    var onTogglePause: (() -> Void)?
    var onToggleFullscreen: (() -> Void)?
    private var localMonitor: Any?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }
    
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            tearDownMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }
    
    deinit {
        tearDownMonitor()
    }
    
    private func installMonitorIfNeeded() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }
    
    private func tearDownMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }
    
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard window?.isKeyWindow == true else { return event }
        guard window?.firstResponder is NSTextView == false else { return event }
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(blockedModifiers).isEmpty else { return event }
        
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
