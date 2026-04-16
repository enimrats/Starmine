import SwiftUI

struct SidebarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var playback: PlaybackStore
    @ObservedObject var danmaku: DanmakuFeatureStore
    @ObservedObject var jellyfin: JellyfinStore
    @Binding var importerPresented: Bool
    @Binding var workspaceSection: WorkspaceSection

    @State private var showJellyfinConnectForm = false
    @State private var showJellyfinRouteForm = false
    @State private var jellyfinServerURL = ""
    @State private var jellyfinUsername = ""
    @State private var jellyfinPassword = ""
    @State private var jellyfinRouteName = ""
    @State private var jellyfinAdditionalRouteURL = ""
    @State private var jellyfinAdditionalRouteName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    importerPresented = true
                } label: {
                    Label("打开视频", systemImage: "play.rectangle.fill")
                        .font(
                            .system(
                                size: 16,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Palette.accent, Palette.accentDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("当前文件")
                        .font(
                            .system(
                                size: 12,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink.opacity(0.55))
                    Text(playback.currentVideoTitle)
                        .font(
                            .system(
                                size: 16,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                }
                .cardStyle()

                jellyfinPanel

                if let account = coordinator.activeJellyfinAccount {
                    Button {
                        withAnimation(
                            .spring(response: 0.28, dampingFraction: 0.88)
                        ) {
                            workspaceSection = .library
                        }
                    } label: {
                        HStack(spacing: 14) {
                            RoundedRectangle(
                                cornerRadius: 18,
                                style: .continuous
                            )
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Palette.accent.opacity(0.88),
                                        Palette.accentDeep.opacity(0.92),
                                    ],
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
                                    .font(
                                        .system(
                                            size: 17,
                                            weight: .bold,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(Palette.ink)
                                Text(
                                    coordinator.selectedJellyfinLibrary?.name
                                        ?? "Jellyfin"
                                )
                                .font(
                                    .system(
                                        size: 13,
                                        weight: .medium,
                                        design: .rounded
                                    )
                                )
                                .foregroundStyle(Palette.ink.opacity(0.62))
                                .lineLimit(2)
                                Text(account.displayTitle)
                                    .font(
                                        .system(
                                            size: 12,
                                            weight: .medium,
                                            design: .rounded
                                        )
                                    )
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

                if playback.currentVideoURL != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(
                            title: "播放信息",
                            systemImage: "gauge.with.needle"
                        )
                        StatRow(
                            title: "状态",
                            value: playback.snapshot.paused ? "暂停" : "播放中"
                        )
                        StatRow(
                            title: "位置",
                            value: timeString(playback.snapshot.position)
                        )
                        StatRow(
                            title: "时长",
                            value: timeString(playback.snapshot.duration)
                        )
                        StatRow(
                            title: "音轨",
                            value: coordinator.selectedAudioTrack?.title ?? "无"
                        )
                        StatRow(
                            title: "字幕",
                            value: coordinator.selectedSubtitleTrack?.title
                                ?? "关闭"
                        )
                    }
                    .cardStyle()
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Palette.ink.opacity(0.45))
                        TextField("搜索番剧", text: $danmaku.searchQuery)
                            .textFieldStyle(.plain)
                            .font(
                                .system(
                                    size: 15,
                                    weight: .medium,
                                    design: .rounded
                                )
                            )
                            .onSubmit {
                                Task {
                                    await coordinator.searchAndAutoloadDanmaku()
                                }
                            }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Palette.surface)
                    )

                    Button {
                        Task { await coordinator.searchAndAutoloadDanmaku() }
                    } label: {
                        HStack {
                            if danmaku.isSearching {
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

                if !danmaku.searchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(
                            title: "弹幕匹配",
                            systemImage: "rectangle.stack.fill"
                        )
                        ForEach(danmaku.searchResults) { anime in
                            Button {
                                coordinator.pickAnime(anime)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(anime.title)
                                        .font(
                                            .system(
                                                size: 15,
                                                weight: .semibold,
                                                design: .rounded
                                            )
                                        )
                                        .foregroundStyle(Palette.ink)
                                        .lineLimit(2)
                                    if !anime.typeDescription.isEmpty
                                        || anime.episodeCount != nil
                                    {
                                        Text(
                                            [
                                                anime.typeDescription,
                                                anime.episodeCount.map {
                                                    "\($0) 集"
                                                },
                                            ].compactMap { $0 }.joined(
                                                separator: " · "
                                            )
                                        )
                                        .font(
                                            .system(
                                                size: 12,
                                                weight: .medium,
                                                design: .rounded
                                            )
                                        )
                                        .foregroundStyle(
                                            Palette.ink.opacity(0.55)
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(
                                    RoundedRectangle(
                                        cornerRadius: 16,
                                        style: .continuous
                                    )
                                    .fill(
                                        danmaku.selectedAnimeID == anime.id
                                            ? Palette.selection
                                            : Palette.surface
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .cardStyle()
                }

                if !danmaku.episodes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(
                            title: "弹幕剧集",
                            systemImage: "text.badge.plus"
                        )
                        ForEach(danmaku.episodes) { episode in
                            Button {
                                coordinator.pickEpisode(episode)
                            } label: {
                                Text(episode.displayTitle)
                                    .font(
                                        .system(
                                            size: 14,
                                            weight: .medium,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(Palette.ink)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(
                                            cornerRadius: 14,
                                            style: .continuous
                                        )
                                        .fill(
                                            danmaku.selectedEpisodeID
                                                == episode.id
                                                ? Palette.selection
                                                : Palette.surface
                                        )
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

    private var jellyfinPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                SectionHeader(title: "Jellyfin", systemImage: "server.rack")
                Spacer()
                if jellyfin.isLoading || jellyfin.isConnecting {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }

            if let account = coordinator.activeJellyfinAccount {
                Menu {
                    ForEach(jellyfin.accounts) { candidate in
                        Button {
                            coordinator.switchJellyfinAccount(candidate.id)
                        } label: {
                            HStack {
                                Text(candidate.displayTitle)
                                Spacer()
                                if candidate.id == jellyfin.selectedAccountID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HeaderCapsule(
                        title: account.displayTitle,
                        systemImage: "person.crop.circle.fill"
                    )
                }

                Menu {
                    ForEach(account.enabledRoutes) { route in
                        Button {
                            coordinator.switchJellyfinRoute(route.id)
                        } label: {
                            HStack {
                                Text(route.name)
                                Spacer()
                                if route.id
                                    == coordinator.activeJellyfinRoute?.id
                                {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HeaderCapsule(
                        title: coordinator.activeJellyfinRoute?.name ?? "自动线路",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                }

                StatRow(title: "服务器", value: account.serverName)
                StatRow(title: "用户", value: account.username)
            } else {
                Text("未连接")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.62))
            }

            HStack(spacing: 10) {
                Button(
                    jellyfin.accounts.isEmpty
                        ? "连接账号" : (showJellyfinConnectForm ? "收起账号表单" : "新增账号")
                ) {
                    showJellyfinConnectForm.toggle()
                }
                .buttonStyle(.bordered)

                Button(showJellyfinRouteForm ? "收起线路表单" : "新增线路") {
                    showJellyfinRouteForm.toggle()
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.activeJellyfinAccount == nil)

                Button {
                    coordinator.refreshJellyfinLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.activeJellyfinAccount == nil)

                Button(role: .destructive) {
                    coordinator.removeSelectedJellyfinAccount()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.activeJellyfinAccount == nil)
            }

            if showJellyfinConnectForm || jellyfin.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(
                        "服务器地址，如 http://192.168.1.10:8096",
                        text: $jellyfinServerURL
                    )
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
                            let success = await coordinator.connectJellyfin(
                                serverURL: serverURL,
                                username: username,
                                password: password,
                                routeName: routeName.nilIfBlank
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

            if showJellyfinRouteForm, coordinator.activeJellyfinAccount != nil {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("新线路地址", text: $jellyfinAdditionalRouteURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("线路备注，可选", text: $jellyfinAdditionalRouteName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let routeURL = jellyfinAdditionalRouteURL
                        let routeName = jellyfinAdditionalRouteName
                        Task {
                            let success = await coordinator.addJellyfinRoute(
                                serverURL: routeURL,
                                routeName: routeName.nilIfBlank
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
}
