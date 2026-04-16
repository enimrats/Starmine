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

    init(
        played: Bool? = nil,
        playbackPositionTicks: Double? = nil,
        playCount: Int? = nil
    ) {
        self.played = played
        self.playbackPositionTicks = playbackPositionTicks
        self.playCount = playCount
    }

    init(payload: [String: Any]) {
        played = payload.bool("Played")
        playbackPositionTicks = payload.double("PlaybackPositionTicks")
        playCount = payload.int("PlayCount")
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
}

struct JellyfinPlaybackMediaSource: Identifiable, Hashable {
    var id: String
    var path: String?
    var container: String?
    var directStreamPath: String?
    var transcodingPath: String?

    init(payload: [String: Any]) {
        id = payload.string("Id") ?? UUID().uuidString
        path = payload.string("Path")
        container = payload.string("Container")
        directStreamPath = payload.string("DirectStreamUrl")
        transcodingPath = payload.string("TranscodingUrl")
    }
}

struct JellyfinPlaybackSession: Hashable {
    var itemID: String
    var mediaSourceID: String?
    var playSessionID: String?
    var streamURL: URL
    var mediaSources: [JellyfinPlaybackMediaSource]
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
