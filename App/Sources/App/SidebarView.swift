import SwiftUI

struct SidebarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var playback: PlaybackStore
    @ObservedObject var danmaku: DanmakuFeatureStore
    @ObservedObject var jellyfin: JellyfinStore
    @Binding var importerPresented: Bool
    @Binding var workspaceSection: WorkspaceSection
    var prefersTouchLayout = false

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
                        .padding(.vertical, prefersTouchLayout ? 16 : 14)
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

                if playback.currentVideoURL != nil {
                    DanmakuPanelView(
                        coordinator: coordinator,
                        playback: playback,
                        danmaku: danmaku,
                        prefersTouchLayout: prefersTouchLayout
                    )
                }
            }
            .padding(.horizontal, prefersTouchLayout ? 16 : 20)
            .padding(.top, prefersTouchLayout ? 16 : 20)
            .padding(.bottom, prefersTouchLayout ? 32 : 20)
        }
        .background(Palette.sidebarBackground.ignoresSafeArea())
        .navigationTitle("Starmine")
        #if !os(macOS)
            .scrollDismissesKeyboard(.interactively)
        #endif
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

            if prefersTouchLayout {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ],
                    spacing: 10
                ) {
                    jellyfinActionButton(
                        title: jellyfin.accounts.isEmpty
                            ? "连接账号"
                            : (showJellyfinConnectForm ? "收起账号" : "新增账号"),
                        systemImage: "person.crop.circle.badge.plus"
                    ) {
                        showJellyfinConnectForm.toggle()
                    }

                    jellyfinActionButton(
                        title: showJellyfinRouteForm ? "收起线路" : "新增线路",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        disabled: coordinator.activeJellyfinAccount == nil
                    ) {
                        showJellyfinRouteForm.toggle()
                    }

                    jellyfinActionButton(
                        title: "刷新媒体库",
                        systemImage: "arrow.clockwise",
                        disabled: coordinator.activeJellyfinAccount == nil
                    ) {
                        coordinator.refreshJellyfinLibrary()
                    }

                    jellyfinActionButton(
                        title: "删除账号",
                        systemImage: "trash",
                        role: .destructive,
                        disabled: coordinator.activeJellyfinAccount == nil
                    ) {
                        coordinator.removeSelectedJellyfinAccount()
                    }
                }
            } else {
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

    @ViewBuilder
    private func jellyfinActionButton(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)

        if role == .destructive {
            button.tint(.red)
        } else {
            button
        }
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
