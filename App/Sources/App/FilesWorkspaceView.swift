import SwiftUI

struct FilesWorkspaceView: View {
    @ObservedObject var coordinator: AppCoordinator
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
    @State private var pendingJellyfinAccountRemoval: JellyfinAccountProfile?
    @State private var offlineSearchQuery = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                #if !os(macOS)
                    Text("文件")
                        .font(
                            .system(size: 32, weight: .bold, design: .rounded)
                        )
                        .padding(.bottom, 4)
                #endif

                Button {
                    importerPresented = true
                } label: {
                    Label("打开本地视频", systemImage: "play.rectangle.fill")
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

                offlineLibraryPanel

                if !jellyfin.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(
                            title: "已连接的媒体库",
                            systemImage: "server.rack"
                        )

                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 280), spacing: 16)
                            ],
                            spacing: 16
                        ) {
                            ForEach(jellyfin.accounts) { account in
                                jellyfinAccountButton(account)
                            }
                        }
                    }
                }

                jellyfinPanel
            }
            .padding(.horizontal, prefersTouchLayout ? 20 : 32)
            .padding(.top, prefersTouchLayout ? 20 : 32)
            .padding(.bottom, prefersTouchLayout ? 40 : 40)
        }
        .alert(
            "删除已连接的媒体库？",
            isPresented: jellyfinAccountRemovalAlertPresented
        ) {
            Button("删除", role: .destructive) {
                guard let account = pendingJellyfinAccountRemoval else {
                    return
                }
                coordinator.removeJellyfinAccount(account.id)
                pendingJellyfinAccountRemoval = nil
            }
            Button("取消", role: .cancel) {
                pendingJellyfinAccountRemoval = nil
            }
        } message: {
            if let account = pendingJellyfinAccountRemoval {
                Text(
                    "将移除“\(account.displayTitle)”及其保存的线路配置，此操作无法撤销。"
                )
            }
        }
    }

    private var offlineLibraryPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                SectionHeader(
                    title: "Jellyfin 离线库",
                    systemImage: "arrow.down.circle.fill"
                )
                Spacer()
                if jellyfin.isSyncingOfflineState {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
                Button("立即同步") {
                    coordinator.syncDownloadedJellyfinEntries()
                }
                .buttonStyle(.bordered)
                .disabled(
                    jellyfin.offlineEntries.isEmpty || jellyfin.accounts.isEmpty
                )
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 168), spacing: 12)
                ],
                spacing: 12
            ) {
                offlineStatCard(
                    title: "已下载",
                    value: "\(jellyfin.offlineDownloadedCount)",
                    tint: Palette.accent
                )
                offlineStatCard(
                    title: "待同步",
                    value: "\(jellyfin.pendingOfflineSyncCount)",
                    tint: Color.orange
                )
                offlineStatCard(
                    title: "冲突",
                    value: "\(jellyfin.offlineConflictCount)",
                    tint: Color.red
                )
            }

            if !jellyfin.offlineDownloadTasks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("下载队列")
                            .font(
                                .system(
                                    size: 16,
                                    weight: .bold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Text("\(jellyfin.offlineDownloadTasks.count) 项")
                            .font(
                                .system(
                                    size: 12,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink.opacity(0.48))
                    }

                    LazyVStack(spacing: 10) {
                        ForEach(jellyfin.offlineDownloadTasks) { task in
                            offlineDownloadTaskRow(task)
                        }
                    }
                }
            }

            if !offlineConflictEntries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("同步冲突")
                            .font(
                                .system(
                                    size: 16,
                                    weight: .bold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Text("\(offlineConflictEntries.count) 项")
                            .font(
                                .system(
                                    size: 12,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Color.red.opacity(0.72))
                    }

                    LazyVStack(spacing: 10) {
                        ForEach(offlineConflictEntries) { entry in
                            offlineConflictRow(entry)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Text("已下载条目")
                        .font(
                            .system(
                                size: 16,
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Text("\(filteredOfflineEntries.count) 条")
                        .font(
                            .system(
                                size: 12,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink.opacity(0.48))
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Palette.ink.opacity(0.42))
                    TextField("搜索离线条目", text: $offlineSearchQuery)
                        .textFieldStyle(.plain)
                        .font(
                            .system(
                                size: 14,
                                weight: .medium,
                                design: .rounded
                            )
                        )
                    if !offlineSearchQuery.isEmpty {
                        Button {
                            offlineSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Palette.ink.opacity(0.36))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.82))
                )

                if filteredOfflineEntries.isEmpty {
                    Text(
                        offlineSearchQuery.isEmpty
                            ? "暂无离线条目"
                            : "无匹配结果"
                    )
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.58))
                    .padding(.vertical, 8)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredOfflineEntries) { entry in
                            offlineEntryRow(entry)
                        }
                    }
                }
            }
        }
        .padding(prefersTouchLayout ? 18 : 22)
        .panelStyle(cornerRadius: 28)
    }

    private var jellyfinPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                SectionHeader(title: "连接新媒体库", systemImage: "network")
                Spacer()
                if jellyfin.isLoading || jellyfin.isConnecting {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
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
                        title: "刷新当前媒体库",
                        systemImage: "arrow.clockwise",
                        disabled: coordinator.activeJellyfinAccount == nil
                    ) {
                        coordinator.refreshJellyfinLibrary()
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button(
                        jellyfin.accounts.isEmpty
                            ? "连接账号"
                            : (showJellyfinConnectForm ? "收起账号表单" : "新增账号")
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
                }
            }

            if showJellyfinConnectForm || jellyfin.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(
                        "服务器地址，如 http://192.168.1.10:8096",
                        text: $jellyfinServerURL
                    )
                    .textFieldStyle(.roundedBorder)
                    #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    #endif
                    TextField("用户名", text: $jellyfinUsername)
                        .textFieldStyle(.roundedBorder)
                        #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        #endif
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
                                if let account = jellyfin.accounts.last {
                                    workspaceSection = .library(account.id)
                                }
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
                        #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        #endif
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

    private var jellyfinAccountRemovalAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingJellyfinAccountRemoval != nil },
            set: { presented in
                if !presented {
                    pendingJellyfinAccountRemoval = nil
                }
            }
        )
    }

    private func jellyfinAccountButton(_ account: JellyfinAccountProfile)
        -> some View
    {
        Button {
            coordinator.switchJellyfinAccount(account.id)
            workspaceSection = .library(account.id)
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Palette.accent.opacity(0.88))
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "film.stack.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayTitle)
                        .font(
                            .system(size: 16, weight: .bold, design: .rounded)
                        )
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(account.serverName)
                        .font(
                            .system(size: 12, weight: .medium, design: .rounded)
                        )
                        .foregroundStyle(Palette.ink.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink.opacity(0.3))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.6))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.8), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                pendingJellyfinAccountRemoval = account
            } label: {
                Label("删除媒体库", systemImage: "trash")
            }
        }
    }

    private var filteredOfflineEntries: [JellyfinOfflineEntry] {
        let keyword = offlineSearchQuery.foldedForSearch()
        guard !keyword.isEmpty else { return jellyfin.offlineEntries }
        return jellyfin.offlineEntries.filter { entry in
            [
                entry.displayTitle,
                entry.detailTitle,
                entry.accountDisplayTitle,
                entry.sourceLibraryName,
                entry.overview,
            ]
            .compactMap { $0?.foldedForSearch() }
            .contains(where: { $0.contains(keyword) })
        }
    }

    private var offlineConflictEntries: [JellyfinOfflineEntry] {
        jellyfin.offlineEntries.filter { $0.syncState == .conflict }
    }

    private func offlineStatCard(
        title: String,
        value: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.58))
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.74))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
    }

    private func offlineDownloadTaskRow(_ task: JellyfinOfflineDownloadTask)
        -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(
                            .system(
                                size: 15,
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(task.detailTitle)
                        .font(
                            .system(
                                size: 12,
                                weight: .medium,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink.opacity(0.56))
                        .lineLimit(2)
                }

                Spacer(minLength: 10)

                Text(task.phase.displayName)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        task.phase == .failed ? .red : Palette.accentDeep
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                task.phase == .failed
                                    ? Color.red.opacity(0.12)
                                    : Palette.selection
                            )
                    )
            }

            ProgressView(value: min(max(task.progress, 0), 1))
                .tint(task.phase == .failed ? .red : Palette.accentDeep)

            HStack(spacing: 10) {
                Text("\(Int(min(max(task.progress, 0), 1) * 100))%")
                    .font(
                        .system(size: 12, weight: .semibold, design: .rounded)
                    )
                    .foregroundStyle(Palette.ink.opacity(0.54))
                    .monospacedDigit()

                if let errorMessage = task.errorMessage?.nilIfBlank {
                    Text(errorMessage)
                        .font(
                            .system(
                                size: 12,
                                weight: .medium,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Color.red.opacity(0.82))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if task.phase == .failed {
                    Button("移除") {
                        jellyfin.dismissOfflineDownloadTask(task.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.74), lineWidth: 1)
        }
    }

    private func offlineConflictRow(_ entry: JellyfinOfflineEntry) -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.displayTitle)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink)
            Text(entry.detailTitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.56))

            HStack(spacing: 10) {
                Button("保留本地记录") {
                    coordinator.resolveDownloadedJellyfinConflict(
                        entry,
                        preferLocal: true
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentDeep)

                Button("采用服务器记录") {
                    coordinator.resolveDownloadedJellyfinConflict(
                        entry,
                        preferLocal: false
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.red.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
        }
    }

    private func offlineEntryRow(_ entry: JellyfinOfflineEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            JellyfinArtworkView(
                url: jellyfin.localArtworkURL(for: entry),
                placeholderSystemName: entry.remoteItemKind == .episode
                    ? "play.tv.fill" : "film.fill",
                cornerRadius: 18
            )
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.displayTitle)
                            .font(
                                .system(
                                    size: 16,
                                    weight: .bold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                        Text(entry.detailTitle)
                            .font(
                                .system(
                                    size: 12,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink.opacity(0.58))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    offlineSyncBadge(entry.syncState)
                }

                Text(
                    [
                        entry.accountDisplayTitle,
                        entry.sourceLibraryName,
                        entry.subtitles.isEmpty
                            ? "无外挂字幕" : "\(entry.subtitles.count) 条外挂字幕",
                        offlineByteCountText(entry.byteCount),
                    ]
                    .compactMap { $0?.nilIfBlank }
                    .joined(separator: " · ")
                )
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.46))
                .lineLimit(2)

                if let overview = entry.overview?.nilIfBlank {
                    Text(overview)
                        .font(
                            .system(
                                size: 12,
                                weight: .medium,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink.opacity(0.42))
                        .lineLimit(2)
                }

                if entry.progressFraction > 0, !entry.isPlayed {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: entry.progressFraction)
                            .tint(Palette.accentDeep)
                        Text("本地进度 \(Int(entry.progressFraction * 100))%")
                            .font(
                                .system(
                                    size: 11,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink.opacity(0.48))
                            .monospacedDigit()
                    }
                }

                if prefersTouchLayout {
                    VStack(alignment: .leading, spacing: 10) {
                        offlineEntryActionButtons(entry)
                    }
                } else {
                    HStack(spacing: 10) {
                        offlineEntryActionButtons(entry)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.78))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.72), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func offlineEntryActionButtons(_ entry: JellyfinOfflineEntry)
        -> some View
    {
        Button("播放") {
            workspaceSection = .player
            coordinator.playDownloadedJellyfinEntry(entry)
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.accentDeep)

        Button(entry.isPlayed ? "标为未看" : "标为已看") {
            coordinator.setDownloadedJellyfinEntryPlayedState(
                entry,
                played: !entry.isPlayed
            )
        }
        .buttonStyle(.bordered)

        Button("删除", role: .destructive) {
            coordinator.removeDownloadedJellyfinEntry(entry)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private func offlineSyncBadge(_ state: JellyfinOfflineSyncState)
        -> some View
    {
        let title: String
        let tint: Color

        switch state {
        case .synced:
            title = "已同步"
            tint = Palette.accentDeep
        case .pendingUpload:
            title = "待回传"
            tint = Color.orange
        case .conflict:
            title = "有冲突"
            tint = Color.red
        case .failed:
            title = "同步失败"
            tint = Color.red
        }

        return Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }

    private func offlineByteCountText(_ byteCount: Int64?) -> String? {
        guard let byteCount, byteCount > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }
}
