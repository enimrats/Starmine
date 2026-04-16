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
                }
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
                        sectionHeader("搜索结果", systemImage: "rectangle.stack.fill")
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
                        sectionHeader("剧集", systemImage: "text.badge.plus")
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
            
            if model.currentVideoURL == nil {
                placeholder
            } else {
                GeometryReader { proxy in
                    playbackStage(in: proxy.size, isImmersive: usesImmersivePlaybackLayout)
                }
            }
        }
        .toolbar {
            if !usesImmersivePlaybackLayout {
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
        }
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
                chromeButton(systemName: model.playback.paused ? "play.fill" : "pause.fill") {
                    notePlaybackInteraction()
                    model.togglePause()
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
    
    private func chromeButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(.white.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
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

private enum Palette {
    static let accent = Color(red: 0.94, green: 0.38, blue: 0.17)
    static let accentDeep = Color(red: 0.79, green: 0.23, blue: 0.08)
    static let canvas = Color(red: 0.95, green: 0.93, blue: 0.89)
    static let sidebarBackground = Color(red: 0.92, green: 0.90, blue: 0.86)
    static let surface = Color.white.opacity(0.82)
    static let selection = Color(red: 1.0, green: 0.84, blue: 0.78)
    static let ink = Color(red: 0.14, green: 0.13, blue: 0.12)
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
