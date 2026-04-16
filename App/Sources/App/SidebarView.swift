import SwiftUI

#if os(macOS)
struct SidebarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var playback: PlaybackStore
    @ObservedObject var danmaku: DanmakuFeatureStore
    @ObservedObject var jellyfin: JellyfinStore
    @Binding var importerPresented: Bool
    @Binding var workspaceSection: WorkspaceSection
    var prefersTouchLayout = false

    var body: some View {
        List(selection: $workspaceSection) {
            Section {
                NavigationLink(value: WorkspaceSection.home) {
                    Label("主页", systemImage: "house")
                }
                NavigationLink(value: WorkspaceSection.files) {
                    Label("文件", systemImage: "folder")
                }
            }

            if !jellyfin.accounts.isEmpty {
                Section("媒体库") {
                    ForEach(jellyfin.accounts) { account in
                        NavigationLink(value: WorkspaceSection.library(account.id)) {
                            Label(account.displayTitle, systemImage: "server.rack")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Starmine")
        .onChange(of: workspaceSection) { newValue in
            if case .library(let id) = newValue {
                coordinator.switchJellyfinAccount(id)
            }
        }
    }
}
#endif
