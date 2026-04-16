import SwiftUI

struct DanmakuPanelView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var playback: PlaybackStore
    @ObservedObject var danmaku: DanmakuFeatureStore
    var prefersTouchLayout = false

    var body: some View {
        let sectionSpacing: CGFloat = prefersTouchLayout ? 16 : 18

        VStack(alignment: .leading, spacing: sectionSpacing) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "弹幕",
                    systemImage: "text.magnifyingglass"
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("替换当前播放弹幕")
                        .font(
                            .system(
                                size: 12,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink.opacity(0.55))
                    Text(
                        playback.currentEpisodeLabel.isEmpty
                            ? playback.currentVideoTitle
                            : playback.currentEpisodeLabel
                    )
                    .font(
                        .system(
                            size: prefersTouchLayout ? 16 : 17,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let selectedAnime = coordinator.selectedAnime {
                            statusChip(
                                title: "已匹配",
                                value: selectedAnime.title
                            )
                        } else {
                            statusChip(title: "状态", value: "未匹配")
                        }

                        if let selectedEpisode = coordinator.selectedEpisode {
                            statusChip(
                                title: "剧集",
                                value: selectedEpisode.displayTitle
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
            .cardStyle()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Palette.ink.opacity(0.45))
                    TextField("搜索番剧或影片名", text: $danmaku.searchQuery)
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
                        Text(
                            coordinator.selectedAnime == nil ? "搜索弹幕" : "重新匹配弹幕"
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentDeep)

                if danmaku.searchResults.isEmpty, danmaku.episodes.isEmpty,
                    !danmaku.isSearching
                {
                    Text("搜索后选择番剧和剧集，会立即替换当前视频的弹幕。")
                        .font(
                            .system(
                                size: 13,
                                weight: .medium,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink.opacity(0.56))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .cardStyle()

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "渲染设置",
                    systemImage: "slider.horizontal.3"
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("字体")
                        .font(
                            .system(
                                size: 12,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink.opacity(0.55))

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                        ],
                        spacing: 10
                    ) {
                        ForEach(DanmakuFontStyle.allCases) { style in
                            Button {
                                danmaku.renderConfiguration.fontStyle = style
                            } label: {
                                HStack(spacing: 8) {
                                    Text(style.title)
                                        .font(
                                            .system(
                                                size: 14,
                                                weight: .semibold,
                                                design: style.swiftUIFontDesign
                                            )
                                        )
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if danmaku.renderConfiguration.fontStyle
                                        == style
                                    {
                                        Image(
                                            systemName: "checkmark.circle.fill"
                                        )
                                        .font(.system(size: 14, weight: .bold))
                                    }
                                }
                                .foregroundStyle(
                                    danmaku.renderConfiguration.fontStyle
                                        == style
                                        ? Palette.accentDeep
                                        : Palette.ink
                                )
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(
                                        cornerRadius: 12,
                                        style: .continuous
                                    )
                                    .fill(
                                        danmaku.renderConfiguration.fontStyle
                                            == style
                                            ? Palette.selection
                                            : Palette.surface
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("字号")
                            .font(
                                .system(
                                    size: 12,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink.opacity(0.55))
                        Spacer()
                        Text("\(Int(danmaku.renderConfiguration.fontSize)) pt")
                            .font(
                                .system(
                                    size: 12,
                                    weight: .bold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink.opacity(0.75))
                    }

                    Slider(
                        value: fontSizeBinding,
                        in: 14...52,
                        step: 1
                    )
                    .tint(Palette.accentDeep)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("透明度")
                            .font(
                                .system(
                                    size: 12,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(Palette.ink.opacity(0.55))
                        Spacer()
                        Text(
                            "\(Int((danmaku.renderConfiguration.opacity * 100).rounded()))%"
                        )
                        .font(
                            .system(
                                size: 12,
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink.opacity(0.75))
                    }

                    Slider(
                        value: opacityBinding,
                        in: 0...1,
                        step: 0.01
                    )
                    .tint(Palette.accentDeep)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("显示区域")
                        .font(
                            .system(
                                size: 12,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(Palette.ink.opacity(0.55))

                    if prefersTouchLayout {
                        Picker("显示区域", selection: displayAreaBinding) {
                            ForEach(DanmakuDisplayArea.allCases) { area in
                                Text(area.title).tag(area)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker("显示区域", selection: displayAreaBinding) {
                            ForEach(DanmakuDisplayArea.allCases) { area in
                                Text(area.title).tag(area)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
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
                                    .foregroundStyle(Palette.ink.opacity(0.55))
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
                                        danmaku.selectedEpisodeID == episode.id
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
    }

    private func statusChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.5))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Palette.surface)
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding {
            danmaku.renderConfiguration.fontSize
        } set: { newValue in
            danmaku.renderConfiguration.fontSize = newValue
        }
    }

    private var opacityBinding: Binding<Double> {
        Binding {
            danmaku.renderConfiguration.opacity
        } set: { newValue in
            danmaku.renderConfiguration.opacity = newValue
        }
    }

    private var displayAreaBinding: Binding<DanmakuDisplayArea> {
        Binding {
            danmaku.renderConfiguration.displayArea
        } set: { newValue in
            danmaku.renderConfiguration.displayArea = newValue
        }
    }
}
