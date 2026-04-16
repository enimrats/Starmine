import SwiftUI

private struct LibraryLayoutMetrics {
    let containerWidth: CGFloat
    let prefersTouchLayout: Bool

    var isCompact: Bool {
        prefersTouchLayout || containerWidth < 760
    }

    var sectionSpacing: CGFloat { isCompact ? 18 : 24 }
    var panelPadding: CGFloat { isCompact ? 16 : 20 }
    var heroCornerRadius: CGFloat { isCompact ? 24 : 30 }
    var heroPosterWidth: CGFloat { isCompact ? 128 : 148 }
    var heroPosterHeight: CGFloat { isCompact ? 188 : 214 }
    var heroBackdropWidth: CGFloat {
        isCompact ? containerWidth : min(520, containerWidth * 0.46)
    }
    var heroTitleSize: CGFloat { isCompact ? 28 : 34 }
    var shelfCardWidth: CGFloat {
        isCompact ? min(max(containerWidth - 20, 220), 252) : 286
    }
    var shelfArtworkWidth: CGFloat { isCompact ? 76 : 88 }
    var shelfArtworkHeight: CGFloat { isCompact ? 108 : 124 }
    var gridSpacing: CGFloat { isCompact ? 14 : 18 }
    var gridMinimum: CGFloat { isCompact ? 148 : 168 }
    var gridMaximum: CGFloat { isCompact ? 190 : 220 }
    var gridPosterHeight: CGFloat { isCompact ? 220 : 246 }
    var episodeArtworkWidth: CGFloat { isCompact ? 96 : 112 }
    var episodeArtworkHeight: CGFloat { isCompact ? 54 : 63 }
}

struct LibraryWorkspaceView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var jellyfin: JellyfinStore
    let hasActivePlayback: Bool
    @Binding var workspaceSection: WorkspaceSection
    @Binding var jellyfinLibrarySearch: String
    var showsInlineSelectionToolbar = false
    var prefersTouchLayout = false

    var body: some View {
        GeometryReader { proxy in
            let metrics = LibraryLayoutMetrics(
                containerWidth: max(320, proxy.size.width),
                prefersTouchLayout: prefersTouchLayout
            )

            Group {
                if coordinator.activeJellyfinAccount == nil {
                    disconnectedState(metrics)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                            if let item = coordinator.selectedJellyfinItem {
                                selectedItemShowcase(item, metrics: metrics)
                                if item.kind.isSeriesLike {
                                    libraryInspectorPanel(metrics: metrics)
                                }
                            } else {
                                libraryShelf(metrics: metrics)
                                libraryExplorerContent(metrics: metrics)
                            }
                        }
                        .padding(.bottom, metrics.isCompact ? 24 : 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func disconnectedState(_ metrics: LibraryLayoutMetrics) -> some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Palette.selection, Palette.accent.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(
                    width: metrics.isCompact ? 132 : 156,
                    height: metrics.isCompact ? 168 : 196
                )
                .overlay {
                    Image(systemName: "server.rack")
                        .font(
                            .system(
                                size: metrics.isCompact ? 38 : 42,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(.white.opacity(0.92))
                }

            Text("Jellyfin")
                .font(
                    .system(
                        size: metrics.isCompact ? 24 : 26,
                        weight: .bold,
                        design: .rounded
                    )
                )
                .foregroundStyle(Palette.ink)

            Text("未连接")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.52))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(metrics.isCompact ? 18 : 24)
        .panelStyle(cornerRadius: metrics.heroCornerRadius)
    }

    private func selectedItemShowcase(
        _ selectedItem: JellyfinMediaItem,
        metrics: LibraryLayoutMetrics
    ) -> some View {
        let subtitle = [
            selectedItem.kind.displayName,
            selectedItem.productionYear.map(String.init),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
        let summary = selectedItem.overview?.nilIfEmpty
        let rating = selectedItem.formattedCommunityRating
        let posterURL = coordinator.jellyfinPosterURL(
            for: selectedItem,
            width: 420,
            height: 630
        )
        let backdropURL = coordinator.jellyfinBackdropURL(
            for: selectedItem,
            width: 1600,
            height: 860
        )

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(
                cornerRadius: metrics.heroCornerRadius,
                style: .continuous
            )
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

            if let backdropURL {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    JellyfinArtworkView(
                        url: backdropURL,
                        placeholderSystemName: "sparkles.tv.fill",
                        cornerRadius: metrics.heroCornerRadius
                    )
                    .frame(width: metrics.heroBackdropWidth)
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
                colors: [
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.24),
                    Color.black.opacity(0.62),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: metrics.heroCornerRadius,
                    style: .continuous
                )
            )

            VStack(alignment: .leading, spacing: metrics.isCompact ? 18 : 20) {
                if showsInlineSelectionToolbar {
                    HStack(spacing: 10) {
                        Button {
                            coordinator.clearSelectedJellyfinItem()
                        } label: {
                            Label("返回媒体库", systemImage: "chevron.backward")
                                .font(
                                    .system(
                                        size: 14,
                                        weight: .semibold,
                                        design: .rounded
                                    )
                                )
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.white.opacity(0.16))
                                .clipShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)

                        Spacer()

                        if jellyfin.isLoading {
                            ProgressView()
                                .tint(.white)
                        }
                    }
                }

                if metrics.isCompact {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Spacer(minLength: 0)
                            posterArtwork(for: selectedItem, url: posterURL, metrics: metrics)
                            Spacer(minLength: 0)
                        }

                        heroCopy(
                            for: selectedItem,
                            subtitle: subtitle,
                            summary: summary,
                            rating: rating,
                            metrics: metrics
                        )

                        heroActionButtons(for: selectedItem, metrics: metrics)
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 24) {
                        posterArtwork(for: selectedItem, url: posterURL, metrics: metrics)

                        VStack(alignment: .leading, spacing: 14) {
                            heroCopy(
                                for: selectedItem,
                                subtitle: subtitle,
                                summary: summary,
                                rating: rating,
                                metrics: metrics
                            )

                            heroActionButtons(for: selectedItem, metrics: metrics)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(metrics.isCompact ? 18 : 28)
        }
        .frame(minHeight: metrics.isCompact ? 0 : 232)
        .overlay {
            RoundedRectangle(
                cornerRadius: metrics.heroCornerRadius,
                style: .continuous
            )
            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 20, x: 0, y: 12)
    }

    private func posterArtwork(
        for selectedItem: JellyfinMediaItem,
        url: URL?,
        metrics: LibraryLayoutMetrics
    ) -> some View {
        JellyfinArtworkView(
            url: url,
            placeholderSystemName: selectedItem.kind.isSeriesLike
                ? "tv.inset.filled" : "film.fill",
            cornerRadius: 24
        )
        .frame(
            width: metrics.heroPosterWidth,
            height: metrics.heroPosterHeight
        )
        .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 8)
    }

    private func heroCopy(
        for selectedItem: JellyfinMediaItem,
        subtitle: String?,
        summary: String?,
        rating: String?,
        metrics: LibraryLayoutMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PillLabel(
                        text: coordinator.selectedJellyfinLibrary?.name
                            ?? selectedItem.kind.displayName
                    )
                    PillLabel(text: selectedItem.kind.displayName)
                }
                .padding(.horizontal, 1)
            }

            Text(selectedItem.name)
                .font(
                    .system(
                        size: metrics.heroTitleSize,
                        weight: .bold,
                        design: .rounded
                    )
                )
                .foregroundStyle(.white)
                .lineLimit(metrics.isCompact ? 3 : 2)

            if let subtitle {
                Text(subtitle)
                    .font(
                        .system(
                            size: 15,
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.white.opacity(0.82))
                    .monospacedDigit()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if let rating {
                        StatPill(text: "评分 \(rating)", emphasized: true)
                            .monospacedDigit()
                    }
                    if let year = selectedItem.productionYear {
                        StatPill(text: String(year))
                    }
                    StatPill(text: selectedItem.kind.displayName)
                }
                .padding(.horizontal, 1)
            }

            if let summary {
                Text(summary)
                    .font(
                        .system(
                            size: 14,
                            weight: .medium,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.white.opacity(0.9))
                    .lineSpacing(3)
                    .lineLimit(metrics.isCompact ? 5 : 4)
            }
        }
    }

    @ViewBuilder
    private func heroActionButtons(
        for selectedItem: JellyfinMediaItem,
        metrics: LibraryLayoutMetrics
    ) -> some View {
        if metrics.isCompact {
            VStack(spacing: 12) {
                if selectedItem.kind.isPlayable {
                    Button(
                        selectedItem.resumePositionSeconds == nil
                            ? "立即播放" : "继续播放"
                    ) {
                        workspaceSection = .player
                        coordinator.playJellyfinMediaItem(selectedItem)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .frame(maxWidth: .infinity)
                }

                Button {
                    coordinator.refreshJellyfinLibrary()
                } label: {
                    Label("刷新媒体库", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                if hasActivePlayback {
                    Button {
                        workspaceSection = .player
                    } label: {
                        Label("切到播放器", systemImage: "play.rectangle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }
        } else {
            HStack(spacing: 12) {
                if selectedItem.kind.isPlayable {
                    Button(
                        selectedItem.resumePositionSeconds == nil
                            ? "立即播放" : "继续播放"
                    ) {
                        workspaceSection = .player
                        coordinator.playJellyfinMediaItem(selectedItem)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                }

                Button {
                    coordinator.refreshJellyfinLibrary()
                } label: {
                    Label("刷新媒体库", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .tint(.white)

                if hasActivePlayback {
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
    }

    private func libraryShelf(metrics: LibraryLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "媒体库",
                systemImage: "rectangle.stack.badge.play"
            )

            if jellyfin.isLoading, jellyfin.libraries.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("载入中")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.ink.opacity(0.68))
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelStyle()
            } else if jellyfin.libraries.isEmpty {
                Text("没有媒体库")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.62))
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelStyle()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: metrics.gridSpacing) {
                        ForEach(jellyfin.libraries) { library in
                            Button {
                                coordinator.selectJellyfinLibrary(library)
                            } label: {
                                HStack(spacing: 14) {
                                    JellyfinArtworkView(
                                        url: coordinator.jellyfinLibraryImageURL(
                                            library,
                                            width: 240,
                                            height: 360
                                        ),
                                        placeholderSystemName: "square.stack.3d.up.fill",
                                        cornerRadius: 22
                                    )
                                    .frame(
                                        width: metrics.shelfArtworkWidth,
                                        height: metrics.shelfArtworkHeight
                                    )

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(library.name)
                                            .font(
                                                .system(
                                                    size: 16,
                                                    weight: .bold,
                                                    design: .rounded
                                                )
                                            )
                                            .foregroundStyle(Palette.ink)
                                            .lineLimit(2)

                                        Text(library.subtitle)
                                            .font(
                                                .system(
                                                    size: 12,
                                                    weight: .medium,
                                                    design: .rounded
                                                )
                                            )
                                            .foregroundStyle(Palette.ink.opacity(0.6))
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 0)

                                    if jellyfin.selectedLibraryID == library.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundStyle(Palette.accentDeep)
                                    }
                                }
                                .padding(14)
                                .frame(width: metrics.shelfCardWidth, alignment: .leading)
                                .background(
                                    RoundedRectangle(
                                        cornerRadius: 26,
                                        style: .continuous
                                    )
                                    .fill(
                                        jellyfin.selectedLibraryID == library.id
                                            ? Palette.selection
                                            : Color.white.opacity(0.86)
                                    )
                                )
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: 26,
                                        style: .continuous
                                    )
                                    .strokeBorder(
                                        jellyfin.selectedLibraryID == library.id
                                            ? Palette.accent.opacity(0.34)
                                            : .white.opacity(0.65),
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

    @ViewBuilder
    private func libraryExplorerContent(metrics: LibraryLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if metrics.isCompact {
                VStack(alignment: .leading, spacing: 12) {
                    explorerHeadline
                    explorerSearchField
                }
            } else {
                HStack(alignment: .center, spacing: 14) {
                    explorerHeadline
                    Spacer()
                    explorerSearchField
                        .frame(maxWidth: 280)
                }
            }

            libraryGridPanel(metrics: metrics)
        }
    }

    private var explorerHeadline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(coordinator.selectedJellyfinLibrary?.name ?? "媒体库")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink)

            Text("当前媒体库共 \(filteredJellyfinItems.count) 个节目")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.58))
        }
    }

    private var explorerSearchField: some View {
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
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.86))
        )
    }

    private func libraryGridPanel(metrics: LibraryLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "节目封面", systemImage: "square.grid.3x3.fill")

            if coordinator.selectedJellyfinLibrary == nil {
                Text("未选择媒体库")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.62))
            } else if jellyfin.isLoading, jellyfin.items.isEmpty {
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
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(
                                minimum: metrics.gridMinimum,
                                maximum: metrics.gridMaximum
                            ),
                            spacing: metrics.gridSpacing
                        )
                    ],
                    spacing: metrics.gridSpacing
                ) {
                    ForEach(filteredJellyfinItems) { item in
                        Button {
                            coordinator.selectJellyfinItem(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                ZStack(alignment: .bottomLeading) {
                                    JellyfinArtworkView(
                                        url: coordinator.jellyfinPosterURL(
                                            for: item,
                                            width: 420,
                                            height: 630
                                        ),
                                        placeholderSystemName: item.kind.isSeriesLike
                                            ? "tv.inset.filled" : "film.fill",
                                        cornerRadius: 24
                                    )
                                    .frame(height: metrics.gridPosterHeight)

                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Spacer()
                                            Text(item.kind.displayName)
                                                .font(
                                                    .system(
                                                        size: 11,
                                                        weight: .bold,
                                                        design: .rounded
                                                    )
                                                )
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(
                                                    Capsule(style: .continuous)
                                                        .fill(Color.black.opacity(0.48))
                                                )
                                        }

                                        Spacer(minLength: 0)

                                        if progressFraction(
                                            position: item.resumePositionSeconds,
                                            durationTicks: item.runTimeTicks
                                        ) > 0 {
                                            GeometryReader { proxy in
                                                Capsule(style: .continuous)
                                                    .fill(Color.white.opacity(0.18))
                                                    .overlay(alignment: .leading) {
                                                        Capsule(style: .continuous)
                                                            .fill(Palette.accent)
                                                            .frame(
                                                                width: max(
                                                                    8,
                                                                    proxy.size.width
                                                                        * progressFraction(
                                                                            position: item.resumePositionSeconds,
                                                                            durationTicks: item.runTimeTicks
                                                                        )
                                                                )
                                                            )
                                                    }
                                            }
                                            .frame(height: 4)
                                        }
                                    }
                                    .padding(12)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                        .font(
                                            .system(
                                                size: 16,
                                                weight: .bold,
                                                design: .rounded
                                            )
                                        )
                                        .foregroundStyle(Palette.ink)
                                        .lineLimit(2)

                                    if let metaLine = item.metaLine.nilIfEmpty {
                                        Text(metaLine)
                                            .font(
                                                .system(
                                                    size: 12,
                                                    weight: .medium,
                                                    design: .rounded
                                                )
                                            )
                                            .foregroundStyle(Palette.ink.opacity(0.58))
                                            .lineLimit(2)
                                            .monospacedDigit()
                                    }

                                    if let overview = item.overview?.nilIfBlank {
                                        Text(overview)
                                            .font(
                                                .system(
                                                    size: 12,
                                                    weight: .medium,
                                                    design: .rounded
                                                )
                                            )
                                            .foregroundStyle(Palette.ink.opacity(0.46))
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .fill(
                                        jellyfin.selectedItemID == item.id
                                            ? Palette.selection
                                            : Color.white.opacity(0.88)
                                    )
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .strokeBorder(
                                        jellyfin.selectedItemID == item.id
                                            ? Palette.accent.opacity(0.34)
                                            : .white.opacity(0.72),
                                        lineWidth: 1
                                    )
                            }
                            .shadow(
                                color: .black.opacity(
                                    jellyfin.selectedItemID == item.id ? 0.09 : 0.04
                                ),
                                radius: 14,
                                x: 0,
                                y: 8
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(metrics.panelPadding)
        .panelStyle(cornerRadius: metrics.heroCornerRadius)
    }

    private func libraryInspectorPanel(metrics: LibraryLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let item = coordinator.selectedJellyfinItem, item.kind.isSeriesLike {
                if !jellyfin.seasons.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(
                            title: "季度",
                            systemImage: "square.grid.2x2.fill"
                        )

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(jellyfin.seasons) { season in
                                    Button {
                                        coordinator.selectJellyfinSeason(season)
                                    } label: {
                                        Text(season.displayTitle)
                                            .font(
                                                .system(
                                                    size: 13,
                                                    weight: .semibold,
                                                    design: .rounded
                                                )
                                            )
                                            .foregroundStyle(
                                                jellyfin.selectedSeasonID == season.id
                                                    ? .white : Palette.ink
                                            )
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 10)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(
                                                        jellyfin.selectedSeasonID
                                                            == season.id
                                                            ? Palette.accentDeep
                                                            : Color.white.opacity(0.82)
                                                    )
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
                        SectionHeader(
                            title: "剧集",
                            systemImage: "play.rectangle.on.rectangle"
                        )
                        Spacer()
                        Text("\(filteredJellyfinEpisodes.count) 集")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.ink.opacity(0.52))
                    }

                    if jellyfin.isLoading, jellyfin.episodes.isEmpty {
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
                                    coordinator.playJellyfinEpisode(episode)
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        JellyfinArtworkView(
                                            url: coordinator.jellyfinEpisodeThumbnailURL(
                                                episode,
                                                width: 320,
                                                height: 180
                                            ),
                                            placeholderSystemName: "play.tv.fill",
                                            cornerRadius: 18
                                        )
                                        .frame(
                                            width: metrics.episodeArtworkWidth,
                                            height: metrics.episodeArtworkHeight
                                        )

                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(episode.displayTitle)
                                                .font(
                                                    .system(
                                                        size: 14,
                                                        weight: .bold,
                                                        design: .rounded
                                                    )
                                                )
                                                .foregroundStyle(Palette.ink)
                                                .lineLimit(2)

                                            if let runtime = runtimeText(
                                                fromTicks: episode.runTimeTicks
                                            ).nilIfEmpty {
                                                Text(runtime)
                                                    .font(
                                                        .system(
                                                            size: 12,
                                                            weight: .semibold,
                                                            design: .rounded
                                                        )
                                                    )
                                                    .foregroundStyle(Palette.ink.opacity(0.58))
                                            }

                                            if let overview = episode.overview?.nilIfBlank {
                                                Text(overview)
                                                    .font(
                                                        .system(
                                                            size: 12,
                                                            weight: .medium,
                                                            design: .rounded
                                                        )
                                                    )
                                                    .foregroundStyle(Palette.ink.opacity(0.46))
                                                    .lineLimit(2)
                                            }
                                        }

                                        Spacer(minLength: 0)

                                        Image(
                                            systemName: jellyfin.selectedEpisodeID == episode.id
                                                ? "speaker.wave.2.circle.fill"
                                                : "play.circle.fill"
                                        )
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundStyle(
                                            jellyfin.selectedEpisodeID == episode.id
                                                ? Palette.accentDeep
                                                : Palette.accent
                                        )
                                    }
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .fill(
                                                jellyfin.selectedEpisodeID == episode.id
                                                    ? Palette.selection
                                                    : Color.white.opacity(0.74)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } else {
                SectionHeader(
                    title: "节目详情",
                    systemImage: "rectangle.stack.fill"
                )

                if let library = coordinator.selectedJellyfinLibrary {
                    if metrics.isCompact {
                        VStack(alignment: .leading, spacing: 12) {
                            JellyfinArtworkView(
                                url: coordinator.jellyfinLibraryImageURL(
                                    library,
                                    width: 360,
                                    height: 540
                                ),
                                placeholderSystemName: "square.stack.3d.up.fill",
                                cornerRadius: 24
                            )
                            .frame(width: 132, height: 192)

                            Text(library.name)
                                .font(
                                    .system(
                                        size: 24,
                                        weight: .bold,
                                        design: .rounded
                                    )
                                )
                                .foregroundStyle(Palette.ink)

                            Text(library.subtitle)
                                .font(
                                    .system(
                                        size: 14,
                                        weight: .semibold,
                                        design: .rounded
                                    )
                                )
                                .foregroundStyle(Palette.ink.opacity(0.56))
                        }
                    } else {
                        HStack(alignment: .top, spacing: 16) {
                            JellyfinArtworkView(
                                url: coordinator.jellyfinLibraryImageURL(
                                    library,
                                    width: 360,
                                    height: 540
                                ),
                                placeholderSystemName: "square.stack.3d.up.fill",
                                cornerRadius: 24
                            )
                            .frame(width: 116, height: 168)

                            VStack(alignment: .leading, spacing: 8) {
                                Text(library.name)
                                    .font(
                                        .system(
                                            size: 24,
                                            weight: .bold,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(Palette.ink)

                                Text(library.subtitle)
                                    .font(
                                        .system(
                                            size: 14,
                                            weight: .semibold,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(Palette.ink.opacity(0.56))
                            }
                        }
                    }
                } else {
                    Text("未选择节目")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.ink.opacity(0.62))
                }
            }
        }
        .padding(metrics.panelPadding)
        .panelStyle(cornerRadius: metrics.heroCornerRadius)
    }

    private var filteredJellyfinItems: [JellyfinMediaItem] {
        let keyword = normalizedLibrarySearch
        guard !keyword.isEmpty else { return jellyfin.items }
        return jellyfin.items.filter { item in
            [item.name, item.originalTitle, item.overview]
                .compactMap { $0?.foldedForSearch() }
                .contains(where: { $0.contains(keyword) })
        }
    }

    private var filteredJellyfinEpisodes: [JellyfinEpisode] {
        let keyword = normalizedLibrarySearch
        guard !keyword.isEmpty else { return jellyfin.episodes }
        return jellyfin.episodes.filter { episode in
            [episode.name, episode.displayTitle, episode.overview]
                .compactMap { $0?.foldedForSearch() }
                .contains(where: { $0.contains(keyword) })
        }
    }

    private var normalizedLibrarySearch: String {
        jellyfinLibrarySearch.foldedForSearch()
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
}
