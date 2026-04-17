import Foundation

enum JellyfinClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unsupportedPayload
    case authenticationFailed
    case authenticationExpired
    case accountNotFound
    case routeNotFound
    case noAvailableRoute
    case serverConflict(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Jellyfin 服务器地址无效。"
        case .invalidResponse:
            return "Jellyfin 返回了无法解析的数据。"
        case .unsupportedPayload:
            return "Jellyfin 返回了当前版本暂不支持的数据格式。"
        case .authenticationFailed:
            return "Jellyfin 登录失败，请检查账号和密码。"
        case .authenticationExpired:
            return "Jellyfin 登录状态已失效，请重新连接账号。"
        case .accountNotFound:
            return "没有找到对应的 Jellyfin 账号。"
        case .routeNotFound:
            return "没有找到对应的 Jellyfin 线路。"
        case .noAvailableRoute:
            return "当前账号没有可用的 Jellyfin 线路。"
        case let .serverConflict(message), let .requestFailed(message):
            return message
        }
    }
}

enum JellyfinURLTools {
    static func normalize(_ rawURL: String) -> String {
        var normalized = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.lowercased().hasPrefix("http://"),
            !normalized.lowercased().hasPrefix("https://")
        {
            normalized = "http://\(normalized)"
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    static func suggestedRouteName(for normalizedURL: String) -> String {
        guard let components = URLComponents(string: normalizedURL) else {
            return "默认线路"
        }
        if let host = components.host, !host.isEmpty {
            if let port = components.port {
                return "\(host):\(port)"
            }
            return host
        }
        return "默认线路"
    }

    static func resolve(
        _ rawPath: String?,
        baseURL: String,
        accessToken: String? = nil
    ) -> URL? {
        guard let rawPath = rawPath?.nilIfBlank else { return nil }
        if rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://") {
            return URL(string: rawPath)
        }

        let normalizedPath = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
        guard
            var components = URLComponents(
                string: "\(baseURL)\(normalizedPath)"
            )
        else {
            return nil
        }

        if let accessToken,
            !(components.queryItems ?? []).contains(where: {
                $0.name.caseInsensitiveCompare("api_key") == .orderedSame
            })
        {
            var queryItems = components.queryItems ?? []
            queryItems.append(
                URLQueryItem(name: "api_key", value: accessToken)
            )
            components.queryItems = queryItems
        }

        return components.url
    }

    static func subtitleFallbackURL(
        baseURL: String,
        accessToken: String,
        itemID: String,
        mediaSourceID: String?,
        streamIndex: Int,
        fileExtension: String
    ) -> URL? {
        var components = URLComponents(
            string:
                "\(baseURL)/Videos/\(itemID)/\(mediaSourceID ?? itemID)/Subtitles/\(streamIndex)/Stream.\(fileExtension)"
        )
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: accessToken)
        ]
        return components?.url
    }
}

enum JellyfinCollectionType: String, Codable, Hashable {
    case tvshows
    case movies
    case mixed
    case unknown

    init(apiValue: String?) {
        switch apiValue?.lowercased() {
        case "tvshows":
            self = .tvshows
        case "movies":
            self = .movies
        case "mixed":
            self = .mixed
        default:
            self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .tvshows:
            return "剧集"
        case .movies:
            return "电影"
        case .mixed:
            return "混合"
        case .unknown:
            return "未分类"
        }
    }
}

enum JellyfinItemKind: String, Codable, Hashable {
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case movie = "Movie"
    case video = "Video"
    case folder = "Folder"
    case boxSet = "BoxSet"
    case collectionFolder = "CollectionFolder"
    case unknown = "Unknown"

    init(apiValue: String?) {
        switch apiValue?.lowercased() {
        case "series":
            self = .series
        case "season":
            self = .season
        case "episode":
            self = .episode
        case "movie":
            self = .movie
        case "video":
            self = .video
        case "folder":
            self = .folder
        case "boxset":
            self = .boxSet
        case "collectionfolder":
            self = .collectionFolder
        default:
            self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .series:
            return "剧集"
        case .season:
            return "季度"
        case .episode:
            return "单集"
        case .movie:
            return "电影"
        case .video:
            return "视频"
        case .folder:
            return "文件夹"
        case .boxSet:
            return "合集"
        case .collectionFolder:
            return "媒体库"
        case .unknown:
            return "未知"
        }
    }

    var isPlayable: Bool {
        switch self {
        case .episode, .movie, .video:
            return true
        default:
            return false
        }
    }

    var isSeriesLike: Bool {
        self == .series
    }
}

struct JellyfinUserData: Codable, Hashable {
    var played: Bool?
    var playbackPositionTicks: Double?
    var playCount: Int?
    var lastPlayedDate: Date?

    init(
        played: Bool? = nil,
        playbackPositionTicks: Double? = nil,
        playCount: Int? = nil,
        lastPlayedDate: Date? = nil
    ) {
        self.played = played
        self.playbackPositionTicks = playbackPositionTicks
        self.playCount = playCount
        self.lastPlayedDate = lastPlayedDate
    }

    init(payload: [String: Any]) {
        played = payload.bool("Played")
        playbackPositionTicks = payload.double("PlaybackPositionTicks")
        playCount = payload.int("PlayCount")
        lastPlayedDate = JellyfinDateParser.parse(
            payload.string("LastPlayedDate")
        )
    }

    var playbackPositionSeconds: Double? {
        playbackPositionTicks.map { $0 / 10_000_000.0 }
    }
}

struct JellyfinRoute: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var url: String
    var priority: Int
    var isEnabled: Bool
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var failureCount: Int

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        priority: Int = 0,
        isEnabled: Bool = true,
        lastSuccessAt: Date? = nil,
        lastFailureAt: Date? = nil,
        failureCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.priority = priority
        self.isEnabled = isEnabled
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.failureCount = failureCount
    }

    var normalizedURL: String {
        JellyfinURLTools.normalize(url)
    }

    func shouldRetry(maxFailures: Int = 3, cooldown: TimeInterval = 1) -> Bool {
        if failureCount < maxFailures {
            return true
        }
        guard let lastFailureAt else {
            return true
        }
        return Date().timeIntervalSince(lastFailureAt) > cooldown
    }

    func markingSuccess(at date: Date = Date()) -> JellyfinRoute {
        var copy = self
        copy.lastSuccessAt = date
        copy.lastFailureAt = nil
        copy.failureCount = 0
        return copy
    }

    func markingFailure(at date: Date = Date()) -> JellyfinRoute {
        var copy = self
        copy.lastFailureAt = date
        copy.failureCount += 1
        return copy
    }
}

struct JellyfinAccountProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var serverID: String
    var serverName: String
    var username: String
    var userID: String
    var accessToken: String
    var routes: [JellyfinRoute]
    var lastSuccessfulRouteID: UUID?
    var lastConnectionAt: Date?
    var lastSelectedLibraryID: String?

    init(
        id: UUID = UUID(),
        serverID: String,
        serverName: String,
        username: String,
        userID: String,
        accessToken: String,
        routes: [JellyfinRoute],
        lastSuccessfulRouteID: UUID? = nil,
        lastConnectionAt: Date? = nil,
        lastSelectedLibraryID: String? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.username = username
        self.userID = userID
        self.accessToken = accessToken
        self.routes = routes
        self.lastSuccessfulRouteID = lastSuccessfulRouteID
        self.lastConnectionAt = lastConnectionAt
        self.lastSelectedLibraryID = lastSelectedLibraryID
    }

    var displayTitle: String {
        "\(username) @ \(serverName)"
    }

    var activeRoute: JellyfinRoute? {
        if let lastSuccessfulRouteID,
            let route = routes.first(where: {
                $0.id == lastSuccessfulRouteID && $0.isEnabled
            })
        {
            return route
        }
        return enabledRoutes.first
    }

    var enabledRoutes: [JellyfinRoute] {
        routes
            .filter(\.isEnabled)
            .sorted { lhs, rhs in
                if lhs.id == lastSuccessfulRouteID {
                    return true
                }
                if rhs.id == lastSuccessfulRouteID {
                    return false
                }
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                switch (lhs.lastSuccessAt, rhs.lastSuccessAt) {
                case let (left?, right?):
                    return left > right
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                        == .orderedAscending
                }
            }
    }

    func markingRouteSuccess(_ routeID: UUID, at date: Date = Date())
        -> JellyfinAccountProfile
    {
        var copy = self
        copy.routes = routes.map { route in
            route.id == routeID ? route.markingSuccess(at: date) : route
        }
        copy.lastSuccessfulRouteID = routeID
        copy.lastConnectionAt = date
        return copy
    }

    func markingRouteFailure(_ routeID: UUID, at date: Date = Date())
        -> JellyfinAccountProfile
    {
        var copy = self
        copy.routes = routes.map { route in
            route.id == routeID ? route.markingFailure(at: date) : route
        }
        return copy
    }
}

struct JellyfinStoreSnapshot: Hashable {
    var accounts: [JellyfinAccountProfile]
    var activeAccountID: UUID?
}

struct JellyfinLibrary: Identifiable, Hashable {
    var id: String
    var name: String
    var collectionType: JellyfinCollectionType
    var imageTag: String?
    var totalItems: Int?

    init(payload: [String: Any]) {
        id = payload.string("Id") ?? UUID().uuidString
        name = payload.string("Name") ?? "未命名媒体库"
        collectionType = JellyfinCollectionType(
            apiValue: payload.string("CollectionType")
        )
        imageTag = payload.dictionary("ImageTags")?.string("Primary")
        totalItems = payload.int("ChildCount")
    }

    var subtitle: String {
        if let totalItems {
            return "\(collectionType.displayName) · \(totalItems) 项"
        }
        return collectionType.displayName
    }
}

struct JellyfinMediaItem: Identifiable, Hashable {
    var id: String
    var name: String
    var overview: String?
    var originalTitle: String?
    var imagePrimaryTag: String?
    var imageBackdropTag: String?
    var kind: JellyfinItemKind
    var productionYear: Int?
    var dateAdded: Date?
    var premiereDate: String?
    var communityRating: String?
    var runTimeTicks: Double?
    var userData: JellyfinUserData?

    init(payload: [String: Any]) {
        id = payload.string("Id") ?? UUID().uuidString
        name = payload.string("Name") ?? "未命名项目"
        overview = payload.string("Overview")
        originalTitle = payload.string("OriginalTitle")
        imagePrimaryTag = payload.dictionary("ImageTags")?.string("Primary")
        imageBackdropTag = payload.strings("BackdropImageTags").first
        kind = JellyfinItemKind(apiValue: payload.string("Type"))
        productionYear = payload.int("ProductionYear")
        dateAdded = JellyfinDateParser.parse(payload.string("DateCreated"))
        premiereDate = payload.string("PremiereDate")
        communityRating = payload.value("CommunityRating").flatMap {
            String(describing: $0).nilIfBlank
        }
        runTimeTicks = payload.double("RunTimeTicks")
        userData = payload.dictionary("UserData").map(
            JellyfinUserData.init(payload:)
        )
    }

    var metaLine: String {
        [
            kind.displayName, productionYear.map(String.init),
            formattedCommunityRating.map { "评分 \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    var formattedCommunityRating: String? {
        guard let communityRating = communityRating?.nilIfBlank else {
            return nil
        }
        guard let value = Double(communityRating) else {
            return communityRating
        }
        return String(format: "%.2f", value)
    }

    var resumePositionSeconds: Double? {
        userData?.playbackPositionSeconds
    }

    var isPlayed: Bool {
        userData?.played == true
    }
}

struct JellyfinHomeItem: Identifiable, Hashable {
    var id: String
    var name: String
    var overview: String?
    var seriesID: String?
    var seriesName: String?
    var seasonID: String?
    var seasonName: String?
    var imagePrimaryTag: String?
    var imageBackdropTag: String?
    var kind: JellyfinItemKind
    var productionYear: Int?
    var communityRating: String?
    var runTimeTicks: Double?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var userData: JellyfinUserData?
    var dateCreated: Date?

    init(payload: [String: Any]) {
        id = payload.string("Id") ?? UUID().uuidString
        name = payload.string("Name") ?? "未命名项目"
        overview = payload.string("Overview")
        seriesID = payload.string("SeriesId")
        seriesName = payload.string("SeriesName")
        seasonID = payload.string("SeasonId")
        seasonName = payload.string("SeasonName")
        imagePrimaryTag = payload.dictionary("ImageTags")?.string("Primary")
        imageBackdropTag = payload.strings("BackdropImageTags").first
        kind = JellyfinItemKind(apiValue: payload.string("Type"))
        productionYear = payload.int("ProductionYear")
        communityRating = payload.value("CommunityRating").flatMap {
            String(describing: $0).nilIfBlank
        }
        runTimeTicks = payload.double("RunTimeTicks")
        indexNumber = payload.int("IndexNumber")
        parentIndexNumber = payload.int("ParentIndexNumber")
        userData = payload.dictionary("UserData").map(
            JellyfinUserData.init(payload:)
        )
        dateCreated = JellyfinDateParser.parse(payload.string("DateCreated"))
    }

    init(mediaItem: JellyfinMediaItem) {
        id = mediaItem.id
        name = mediaItem.name
        overview = mediaItem.overview
        seriesID = nil
        seriesName = nil
        seasonID = nil
        seasonName = nil
        imagePrimaryTag = mediaItem.imagePrimaryTag
        imageBackdropTag = mediaItem.imageBackdropTag
        kind = mediaItem.kind
        productionYear = mediaItem.productionYear
        communityRating = mediaItem.communityRating
        runTimeTicks = mediaItem.runTimeTicks
        indexNumber = nil
        parentIndexNumber = nil
        userData = mediaItem.userData
        dateCreated = mediaItem.dateAdded
    }

    init(episode: JellyfinEpisode) {
        id = episode.id
        name = episode.name
        overview = episode.overview
        seriesID = episode.seriesID
        seriesName = episode.seriesName
        seasonID = episode.seasonID
        seasonName = episode.seasonName
        imagePrimaryTag = episode.imagePrimaryTag
        imageBackdropTag = nil
        kind = .episode
        productionYear = nil
        communityRating = nil
        runTimeTicks = episode.runTimeTicks
        indexNumber = episode.indexNumber
        parentIndexNumber = episode.parentIndexNumber
        userData = episode.userData
        dateCreated = nil
    }

    var displayTitle: String {
        if kind == .episode {
            return seriesName ?? name
        }
        return name
    }

    var detailTitle: String {
        if kind == .episode {
            return episodeDisplayTitle
        }
        return metaLine.nilIfEmpty ?? kind.displayName
    }

    var metaLine: String {
        [
            kind.displayName,
            productionYear.map(String.init),
            formattedCommunityRating.map { "评分 \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    var episodeDisplayTitle: String {
        if let parentIndexNumber, let indexNumber {
            return "S\(parentIndexNumber)E\(indexNumber) · \(name)"
        }
        if let indexNumber {
            return "第 \(indexNumber) 集 · \(name)"
        }
        return name
    }

    var formattedCommunityRating: String? {
        guard let communityRating = communityRating?.nilIfBlank else {
            return nil
        }
        guard let value = Double(communityRating) else {
            return communityRating
        }
        return String(format: "%.2f", value)
    }

    var resumePositionSeconds: Double? {
        userData?.playbackPositionSeconds
    }

    var progressFraction: Double {
        guard let position = resumePositionSeconds, let runTimeTicks else {
            return 0
        }
        let duration = runTimeTicks / 10_000_000.0
        guard duration > 0 else { return 0 }
        return max(0, min(1, position / duration))
    }

    var isPlayed: Bool {
        userData?.played == true
    }
}

struct JellyfinSeason: Identifiable, Hashable {
    var id: String
    var name: String
    var seriesID: String?
    var seriesName: String?
    var imagePrimaryTag: String?
    var indexNumber: Int?

    init(payload: [String: Any]) {
        id = payload.string("Id") ?? UUID().uuidString
        name = payload.string("Name") ?? "未命名季度"
        seriesID = payload.string("SeriesId")
        seriesName = payload.string("SeriesName")
        imagePrimaryTag = payload.dictionary("ImageTags")?.string("Primary")
        indexNumber = payload.int("IndexNumber")
    }

    var displayTitle: String {
        if let indexNumber {
            return "第 \(indexNumber) 季"
        }
        return name
    }
}

struct JellyfinEpisode: Identifiable, Hashable {
    var id: String
    var name: String
    var overview: String?
    var seriesID: String?
    var seriesName: String?
    var seasonID: String?
    var seasonName: String?
    var imagePrimaryTag: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var runTimeTicks: Double?
    var userData: JellyfinUserData?

    init(payload: [String: Any]) {
        id = payload.string("Id") ?? UUID().uuidString
        name = payload.string("Name") ?? "未命名剧集"
        overview = payload.string("Overview")
        seriesID = payload.string("SeriesId")
        seriesName = payload.string("SeriesName")
        seasonID = payload.string("SeasonId")
        seasonName = payload.string("SeasonName")
        imagePrimaryTag = payload.dictionary("ImageTags")?.string("Primary")
        indexNumber = payload.int("IndexNumber")
        parentIndexNumber = payload.int("ParentIndexNumber")
        runTimeTicks = payload.double("RunTimeTicks")
        userData = payload.dictionary("UserData").map(
            JellyfinUserData.init(payload:)
        )
    }

    var displayTitle: String {
        if let parentIndexNumber, let indexNumber {
            return "S\(parentIndexNumber)E\(indexNumber) · \(name)"
        }
        if let indexNumber {
            return "第 \(indexNumber) 集 · \(name)"
        }
        return name
    }

    var danmakuEpisodeOrdinal: Int? {
        if let indexNumber {
            return indexNumber
        }
        return DandanplaySearchHeuristics.extractEpisodeNumber(
            from: displayTitle
        )
            ?? DandanplaySearchHeuristics.extractEpisodeNumber(from: name)
    }

    var resumePositionSeconds: Double? {
        userData?.playbackPositionSeconds
    }

    var isPlayed: Bool {
        userData?.played == true
    }
}

struct JellyfinPlaybackMediaSource: Identifiable, Hashable {
    var id: String
    var name: String?
    var path: String?
    var container: String?
    var directStreamPath: String?
    var transcodingPath: String?
    var subtitleStreams: [JellyfinPlaybackSubtitleStream]

    init(payload: [String: Any]) {
        id = payload.string("Id") ?? UUID().uuidString
        name = payload.string("Name")
        path = payload.string("Path")
        container = payload.string("Container")
        directStreamPath = payload.string("DirectStreamUrl")
        transcodingPath = payload.string("TranscodingUrl")
        subtitleStreams = payload.dictionaries("MediaStreams")
            .compactMap(JellyfinPlaybackSubtitleStream.init(payload:))
    }
}

struct JellyfinPlaybackSession: Hashable {
    var itemID: String
    var mediaSourceID: String?
    var playSessionID: String?
    var streamURL: URL
    var mediaSources: [JellyfinPlaybackMediaSource]
}

struct JellyfinPlaybackSubtitleStream: Identifiable, Hashable, Codable {
    var index: Int
    var title: String?
    var languageCode: String?
    var codec: String?
    var isExternal: Bool
    var isDefault: Bool
    var isForced: Bool
    var deliveryMethod: String?
    var deliveryURLPath: String?
    var streamURL: URL?

    init?(
        payload: [String: Any]
    ) {
        guard
            payload.string("Type")?.caseInsensitiveCompare("Subtitle")
                == .orderedSame,
            let index = payload.int("Index")
        else {
            return nil
        }
        self.index = index
        title =
            payload.string("DisplayTitle")
            ?? payload.string("Title")
            ?? payload.string("LocalizedDisplayTitle")
        languageCode = payload.string("Language")
        codec = payload.string("Codec")
        isExternal = payload.bool("IsExternal") ?? false
        isDefault = payload.bool("IsDefault") ?? false
        isForced = payload.bool("IsForced") ?? false
        deliveryMethod = payload.string("DeliveryMethod")
        deliveryURLPath = payload.string("DeliveryUrl")
        streamURL = nil
    }

    var id: String {
        "subtitle-\(index)-\(languageCode ?? "und")"
    }

    var fileExtension: String {
        if let pathExtension = streamURL?.pathExtension.nilIfBlank {
            return pathExtension
        }
        if let deliveryPath = deliveryURLPath?.nilIfBlank,
            let pathExtension = URL(string: deliveryPath)?.pathExtension
                .nilIfBlank
        {
            return pathExtension
        }
        if let codec = codec?.nilIfBlank {
            return codec.lowercased()
        }
        return "srt"
    }

    var displayTitle: String {
        let baseTitle =
            title?.nilIfBlank
            ?? languageCode?.uppercased()
            ?? "字幕 \(index + 1)"
        let detail = [
            languageCode?.uppercased(),
            codec?.uppercased(),
            isExternal ? "外部" : nil,
            isDefault ? "默认" : nil,
            isForced ? "强制" : nil,
        ]
        .compactMap { $0?.nilIfBlank }
        .filter { $0.caseInsensitiveCompare(baseTitle) != .orderedSame }
        .joined(separator: " · ")
        if detail.isEmpty {
            return baseTitle
        }
        return "\(baseTitle) · \(detail)"
    }

    func resolving(
        baseURL: String,
        accessToken: String,
        itemID: String,
        mediaSourceID: String?
    ) -> JellyfinPlaybackSubtitleStream {
        var copy = self
        copy.streamURL =
            JellyfinURLTools.resolve(
                deliveryURLPath,
                baseURL: baseURL,
                accessToken: accessToken
            )
            ?? JellyfinURLTools.subtitleFallbackURL(
                baseURL: baseURL,
                accessToken: accessToken,
                itemID: itemID,
                mediaSourceID: mediaSourceID,
                streamIndex: index,
                fileExtension: fileExtension
            )
        return copy
    }
}

enum JellyfinOfflineSyncState: String, Codable, Hashable {
    case synced
    case pendingUpload
    case conflict
    case failed
}

enum JellyfinOfflineDownloadPhase: String, Hashable {
    case queued
    case resolving
    case downloadingVideo
    case downloadingSubtitles
    case downloadingArtwork
    case finalizing
    case failed

    var displayName: String {
        switch self {
        case .queued:
            return "排队中"
        case .resolving:
            return "整理元数据"
        case .downloadingVideo:
            return "下载视频"
        case .downloadingSubtitles:
            return "下载字幕"
        case .downloadingArtwork:
            return "下载封面"
        case .finalizing:
            return "整理本地副本"
        case .failed:
            return "下载失败"
        }
    }
}

struct JellyfinOfflineSubtitle: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var languageCode: String?
    var relativePath: String
    var isDefault: Bool
    var isForced: Bool

    init(
        id: UUID = UUID(),
        title: String,
        languageCode: String?,
        relativePath: String,
        isDefault: Bool = false,
        isForced: Bool = false
    ) {
        self.id = id
        self.title = title
        self.languageCode = languageCode
        self.relativePath = relativePath
        self.isDefault = isDefault
        self.isForced = isForced
    }
}

struct JellyfinOfflineEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var serverID: String
    var userID: String
    var accountDisplayTitle: String
    var sourceLibraryName: String?
    var remoteItemID: String
    var remoteItemKind: JellyfinItemKind
    var title: String
    var episodeLabel: String
    var collectionTitle: String?
    var overview: String?
    var seriesID: String?
    var seriesTitle: String?
    var seasonID: String?
    var seasonTitle: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var productionYear: Int?
    var communityRating: String?
    var runTimeTicks: Double?
    var videoRelativePath: String
    var posterRelativePath: String?
    var backdropRelativePath: String?
    var thumbnailRelativePath: String?
    var seasonPosterRelativePath: String?
    var subtitles: [JellyfinOfflineSubtitle]
    var localUserData: JellyfinUserData
    var baselineUserData: JellyfinUserData
    var conflictingRemoteUserData: JellyfinUserData?
    var syncState: JellyfinOfflineSyncState
    var syncErrorMessage: String?
    var downloadedAt: Date
    var lastLocalUpdateAt: Date?
    var lastSyncAt: Date?
    var byteCount: Int64?

    init(
        id: UUID = UUID(),
        serverID: String,
        userID: String,
        accountDisplayTitle: String,
        sourceLibraryName: String?,
        remoteItemID: String,
        remoteItemKind: JellyfinItemKind,
        title: String,
        episodeLabel: String,
        collectionTitle: String?,
        overview: String?,
        seriesID: String?,
        seriesTitle: String?,
        seasonID: String?,
        seasonTitle: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        productionYear: Int?,
        communityRating: String?,
        runTimeTicks: Double?,
        videoRelativePath: String,
        posterRelativePath: String?,
        backdropRelativePath: String?,
        thumbnailRelativePath: String?,
        seasonPosterRelativePath: String?,
        subtitles: [JellyfinOfflineSubtitle],
        localUserData: JellyfinUserData,
        baselineUserData: JellyfinUserData,
        conflictingRemoteUserData: JellyfinUserData? = nil,
        syncState: JellyfinOfflineSyncState = .synced,
        syncErrorMessage: String? = nil,
        downloadedAt: Date = Date(),
        lastLocalUpdateAt: Date? = nil,
        lastSyncAt: Date? = nil,
        byteCount: Int64? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.userID = userID
        self.accountDisplayTitle = accountDisplayTitle
        self.sourceLibraryName = sourceLibraryName
        self.remoteItemID = remoteItemID
        self.remoteItemKind = remoteItemKind
        self.title = title
        self.episodeLabel = episodeLabel
        self.collectionTitle = collectionTitle
        self.overview = overview
        self.seriesID = seriesID
        self.seriesTitle = seriesTitle
        self.seasonID = seasonID
        self.seasonTitle = seasonTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.productionYear = productionYear
        self.communityRating = communityRating
        self.runTimeTicks = runTimeTicks
        self.videoRelativePath = videoRelativePath
        self.posterRelativePath = posterRelativePath
        self.backdropRelativePath = backdropRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.seasonPosterRelativePath = seasonPosterRelativePath
        self.subtitles = subtitles
        self.localUserData = localUserData
        self.baselineUserData = baselineUserData
        self.conflictingRemoteUserData = conflictingRemoteUserData
        self.syncState = syncState
        self.syncErrorMessage = syncErrorMessage
        self.downloadedAt = downloadedAt
        self.lastLocalUpdateAt = lastLocalUpdateAt
        self.lastSyncAt = lastSyncAt
        self.byteCount = byteCount
    }

    var displayTitle: String {
        if remoteItemKind == .episode {
            return seriesTitle ?? title
        }
        return title
    }

    var detailTitle: String {
        if remoteItemKind == .episode {
            return episodeLabel.nilIfBlank ?? title
        }
        return title
    }

    var progressFraction: Double {
        guard let position = localUserData.playbackPositionSeconds,
            let runTimeTicks
        else {
            return 0
        }
        let duration = runTimeTicks / 10_000_000.0
        guard duration > 0 else { return 0 }
        return max(0, min(1, position / duration))
    }

    var isPlayed: Bool {
        localUserData.played == true
    }
}

struct JellyfinOfflineDownloadTask: Identifiable, Hashable {
    var id: UUID
    var remoteItemID: String
    var title: String
    var detailTitle: String
    var itemKind: JellyfinItemKind
    var phase: JellyfinOfflineDownloadPhase
    var progress: Double
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        remoteItemID: String,
        title: String,
        detailTitle: String,
        itemKind: JellyfinItemKind,
        phase: JellyfinOfflineDownloadPhase = .queued,
        progress: Double = 0.05,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.remoteItemID = remoteItemID
        self.title = title
        self.detailTitle = detailTitle
        self.itemKind = itemKind
        self.phase = phase
        self.progress = progress
        self.errorMessage = errorMessage
    }
}

enum JellyfinDateParser {
    private static let internet = ISO8601DateFormatter()
    private static let internetWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        return formatter
    }()

    static func parse(_ rawValue: String?) -> Date? {
        guard let rawValue = rawValue?.nilIfBlank else { return nil }
        return internetWithFractional.date(from: rawValue)
            ?? internet.date(from: rawValue)
    }
}

extension JellyfinMediaItem {
    init(homeItem: JellyfinHomeItem) {
        id = homeItem.id
        name = homeItem.name
        overview = homeItem.overview
        originalTitle = nil
        imagePrimaryTag = homeItem.imagePrimaryTag
        imageBackdropTag = homeItem.imageBackdropTag
        kind = homeItem.kind
        productionYear = homeItem.productionYear
        dateAdded = homeItem.dateCreated
        premiereDate = nil
        communityRating = homeItem.communityRating
        runTimeTicks = homeItem.runTimeTicks
        userData = homeItem.userData
    }
}

extension JellyfinEpisode {
    init(homeItem: JellyfinHomeItem) {
        id = homeItem.id
        name = homeItem.name
        overview = homeItem.overview
        seriesID = homeItem.seriesID
        seriesName = homeItem.seriesName
        seasonID = homeItem.seasonID
        seasonName = homeItem.seasonName
        imagePrimaryTag = homeItem.imagePrimaryTag
        indexNumber = homeItem.indexNumber
        parentIndexNumber = homeItem.parentIndexNumber
        runTimeTicks = homeItem.runTimeTicks
        userData = homeItem.userData
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let string = self[key] as? String {
            return string.nilIfBlank
        }
        if let number = self[key] as? NSNumber {
            return number.stringValue.nilIfBlank
        }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let int = self[key] as? Int {
            return int
        }
        if let number = self[key] as? NSNumber {
            return number.intValue
        }
        if let string = self[key] as? String {
            return Int(string)
        }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let double = self[key] as? Double {
            return double
        }
        if let number = self[key] as? NSNumber {
            return number.doubleValue
        }
        if let string = self[key] as? String {
            return Double(string)
        }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let bool = self[key] as? Bool {
            return bool
        }
        if let number = self[key] as? NSNumber {
            return number.boolValue
        }
        if let string = self[key] as? String {
            return Bool(string)
        }
        return nil
    }

    func dictionary(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func dictionaries(_ key: String) -> [[String: Any]] {
        (self[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    func strings(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { value in
            if let string = value as? String {
                return string.nilIfBlank
            }
            if let number = value as? NSNumber {
                return number.stringValue.nilIfBlank
            }
            return nil
        } ?? []
    }

    func value(_ key: String) -> Any? {
        self[key]
    }
}
