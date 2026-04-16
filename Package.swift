// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "StarmineCore",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "StarmineCore", targets: ["StarmineCore"]),
    ],
    targets: [
        .target(
            name: "StarmineCore",
            path: "App/Sources",
            exclude: [
                "App",
                "Features/Player/MPVPlayerController.swift",
                "Features/Player/MPVVideoHost.swift",
                "Features/Player/PlaybackPlatformSupport.swift",
                "Features/Player/PlaybackSeekBar.swift",
                "Features/Player/PlaybackStore.swift",
                "Features/Player/SystemMediaController.swift",
                "Features/Jellyfin/JellyfinArtworkView.swift",
                "Features/Jellyfin/LibraryWorkspaceView.swift",
                "Shared/AppTheme.swift",
            ],
            sources: [
                "Shared/AppErrorState.swift",
                "Shared/String+Search.swift",
                "Features/Danmaku/DandanplayClient.swift",
                "Features/Danmaku/DandanplaySearchHeuristics.swift",
                "Features/Danmaku/DanmakuFeatureStore.swift",
                "Features/Danmaku/DanmakuModels.swift",
                "Features/Danmaku/DanmakuRendererStore.swift",
                "Features/Jellyfin/JellyfinClient.swift",
                "Features/Jellyfin/JellyfinModels.swift",
                "Features/Jellyfin/JellyfinStore.swift",
                "Features/Player/PlaybackModels.swift",
            ]
        ),
        .testTarget(
            name: "StarmineCoreTests",
            dependencies: ["StarmineCore"],
            path: "Tests/StarmineCoreTests"
        ),
    ]
)
