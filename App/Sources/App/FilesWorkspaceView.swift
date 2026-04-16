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
}
