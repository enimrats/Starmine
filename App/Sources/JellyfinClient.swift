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
    
    init(played: Bool? = nil, playbackPositionTicks: Double? = nil, playCount: Int? = nil) {
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
        JellyfinClient.normalize(url)
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
           let route = routes.first(where: { $0.id == lastSuccessfulRouteID && $0.isEnabled })
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
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }
    }
    
    func markingRouteSuccess(_ routeID: UUID, at date: Date = Date()) -> JellyfinAccountProfile {
        var copy = self
        copy.routes = routes.map { route in
            route.id == routeID ? route.markingSuccess(at: date) : route
        }
        copy.lastSuccessfulRouteID = routeID
        copy.lastConnectionAt = date
        return copy
    }
    
    func markingRouteFailure(_ routeID: UUID, at date: Date = Date()) -> JellyfinAccountProfile {
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
        collectionType = JellyfinCollectionType(apiValue: payload.string("CollectionType"))
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
        communityRating = payload.value("CommunityRating").flatMap { String(describing: $0).nilIfBlank }
        runTimeTicks = payload.double("RunTimeTicks")
        userData = payload.dictionary("UserData").map(JellyfinUserData.init(payload:))
    }
    
    var metaLine: String {
        [kind.displayName, productionYear.map(String.init), formattedCommunityRating.map { "评分 \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
    
    var formattedCommunityRating: String? {
        guard let communityRating = communityRating?.nilIfBlank else { return nil }
        guard let value = Double(communityRating) else { return communityRating }
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
        userData = payload.dictionary("UserData").map(JellyfinUserData.init(payload:))
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

actor JellyfinClient {
    static let shared = JellyfinClient()
    
    private static let accountsKey = "starmine.jellyfin.accounts"
    private static let activeAccountKey = "starmine.jellyfin.active-account"
    private static let appVersion = "0.1"
    private static let clientName = "Starmine"
    private static let clientDevice = "Apple"
    private static let clientDeviceID = "StarmineApple"
    
    private let session: URLSession
    private var accounts: [JellyfinAccountProfile] = []
    private var activeAccountID: UUID?
    private var isLoaded = false
    
    init(session: URLSession = .shared) {
        self.session = session
    }
    
    static func normalize(_ rawURL: String) -> String {
        var normalized = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.lowercased().hasPrefix("http://"), !normalized.lowercased().hasPrefix("https://") {
            normalized = "http://\(normalized)"
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
    
    func snapshot() async -> JellyfinStoreSnapshot {
        await ensureLoaded()
        return storeSnapshot()
    }
    
    func connect(
        serverURL: String,
        username: String,
        password: String,
        routeName: String?
    ) async throws -> JellyfinStoreSnapshot {
        await ensureLoaded()
        
        let normalizedURL = Self.normalize(serverURL)
        let publicInfo = try await fetchPublicInfo(baseURL: normalizedURL)
        let auth = try await authenticate(
            baseURL: normalizedURL,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
        
        if let conflicting = accounts.first(where: { profile in
            profile.routes.contains(where: { $0.normalizedURL == normalizedURL }) && profile.serverID != publicInfo.serverID
        }) {
            throw JellyfinClientError.serverConflict("该地址已经绑定到另一台 Jellyfin 服务器：\(conflicting.serverName)。")
        }
        
        if let accountIndex = accounts.firstIndex(where: {
            $0.serverID == publicInfo.serverID
                && $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) {
            var account = accounts[accountIndex]
            if !account.routes.contains(where: { $0.normalizedURL == normalizedURL }) {
                let nextPriority = (account.routes.map(\.priority).max() ?? -1) + 1
                account.routes.append(
                    JellyfinRoute(
                        name: routeName?.nilIfBlank ?? suggestedRouteName(for: normalizedURL),
                        url: normalizedURL,
                        priority: nextPriority
                    )
                )
            }
            account.serverName = publicInfo.serverName
            account.userID = auth.userID
            account.accessToken = auth.accessToken
            if let route = account.routes.first(where: { $0.normalizedURL == normalizedURL }) {
                account = account.markingRouteSuccess(route.id)
            }
            accounts[accountIndex] = account
            activeAccountID = account.id
            await save()
            return storeSnapshot()
        }
        
        let route = JellyfinRoute(
            name: routeName?.nilIfBlank ?? suggestedRouteName(for: normalizedURL),
            url: normalizedURL,
            priority: 0
        )
        let account = JellyfinAccountProfile(
            serverID: publicInfo.serverID,
            serverName: publicInfo.serverName,
            username: username,
            userID: auth.userID,
            accessToken: auth.accessToken,
            routes: [route],
            lastSuccessfulRouteID: route.id,
            lastConnectionAt: Date()
        )
        accounts.append(account)
        activeAccountID = account.id
        await save()
        return storeSnapshot()
    }
    
    func setActiveAccount(_ accountID: UUID) async throws -> JellyfinStoreSnapshot {
        await ensureLoaded()
        guard accounts.contains(where: { $0.id == accountID }) else {
            throw JellyfinClientError.accountNotFound
        }
        activeAccountID = accountID
        await save()
        return storeSnapshot()
    }
    
    func removeAccount(_ accountID: UUID) async throws -> JellyfinStoreSnapshot {
        await ensureLoaded()
        guard accounts.contains(where: { $0.id == accountID }) else {
            throw JellyfinClientError.accountNotFound
        }
        accounts.removeAll(where: { $0.id == accountID })
        if activeAccountID == accountID {
            activeAccountID = accounts.first?.id
        }
        await save()
        return storeSnapshot()
    }
    
    func addRoute(
        accountID: UUID,
        serverURL: String,
        routeName: String?
    ) async throws -> JellyfinStoreSnapshot {
        await ensureLoaded()
        guard let accountIndex = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw JellyfinClientError.accountNotFound
        }
        
        let normalizedURL = Self.normalize(serverURL)
        let publicInfo = try await fetchPublicInfo(baseURL: normalizedURL)
        var account = accounts[accountIndex]
        
        guard publicInfo.serverID == account.serverID else {
            throw JellyfinClientError.serverConflict("这条地址属于另一台 Jellyfin 服务器，不能添加到当前账号。")
        }
        
        if account.routes.contains(where: { $0.normalizedURL == normalizedURL }) {
            return storeSnapshot()
        }
        
        let nextPriority = (account.routes.map(\.priority).max() ?? -1) + 1
        account.routes.append(
            JellyfinRoute(
                name: routeName?.nilIfBlank ?? suggestedRouteName(for: normalizedURL),
                url: normalizedURL,
                priority: nextPriority
            )
        )
        accounts[accountIndex] = account
        await save()
        return storeSnapshot()
    }
    
    func switchRoute(
        accountID: UUID,
        routeID: UUID
    ) async throws -> JellyfinStoreSnapshot {
        await ensureLoaded()
        guard let accountIndex = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw JellyfinClientError.accountNotFound
        }
        let account = accounts[accountIndex]
        guard let route = account.routes.first(where: { $0.id == routeID }) else {
            throw JellyfinClientError.routeNotFound
        }
        
        do {
            _ = try await validateAuthenticatedRoute(account: account, route: route)
            accounts[accountIndex] = account.markingRouteSuccess(route.id)
            activeAccountID = accountID
            await save()
            return storeSnapshot()
        } catch {
            accounts[accountIndex] = account.markingRouteFailure(route.id)
            await save()
            throw error
        }
    }
    
    func rememberSelectedLibrary(accountID: UUID, libraryID: String?) async -> JellyfinStoreSnapshot {
        await ensureLoaded()
        guard let accountIndex = accounts.firstIndex(where: { $0.id == accountID }) else {
            return storeSnapshot()
        }
        accounts[accountIndex].lastSelectedLibraryID = libraryID
        if activeAccountID == nil {
            activeAccountID = accountID
        }
        await save()
        return storeSnapshot()
    }
    
    func loadLibraries(accountID: UUID) async throws -> [JellyfinLibrary] {
        let response = try await authenticatedRequest(
            accountID: accountID,
            path: "/UserViews?userId=\(try userID(for: accountID))"
        )
        let payload = try JSONObject(data: response.data)
        let libraries = payload.dictionaries("Items")
            .map(JellyfinLibrary.init(payload:))
            .filter { library in
                switch library.collectionType {
                case .tvshows, .movies, .mixed:
                    return true
                case .unknown:
                    return false
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        if let accountIndex = accounts.firstIndex(where: { $0.id == accountID }) {
            if let currentLibraryID = accounts[accountIndex].lastSelectedLibraryID,
               libraries.contains(where: { $0.id == currentLibraryID })
            {
                // keep existing selection
            } else {
                accounts[accountIndex].lastSelectedLibraryID = libraries.first?.id
                await save()
            }
        }
        
        return libraries
    }
    
    func loadLibraryItems(accountID: UUID, libraryID: String) async throws -> [JellyfinMediaItem] {
        let path = [
            "/Items?ParentId=\(libraryID)",
            "Recursive=true",
            "IncludeItemTypes=Series,Movie,Video",
            "SortBy=SortName",
            "SortOrder=Ascending",
            "Limit=500",
            "Fields=Overview,ProductionYear,OriginalTitle,DateCreated,PremiereDate,CommunityRating,RunTimeTicks,UserData,ImageTags,BackdropImageTags",
            "userId=\(try userID(for: accountID))",
        ].joined(separator: "&").replacingOccurrences(of: "?&", with: "?")
        
        let response = try await authenticatedRequest(accountID: accountID, path: path)
        let payload = try JSONObject(data: response.data)
        return payload.dictionaries("Items")
            .map(JellyfinMediaItem.init(payload:))
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
    
    func loadSeasons(accountID: UUID, seriesID: String) async throws -> [JellyfinSeason] {
        let response = try await authenticatedRequest(
            accountID: accountID,
            path: "/Shows/\(seriesID)/Seasons?userId=\(try userID(for: accountID))&Fields=ImageTags,SeriesName,IndexNumber"
        )
        let payload = try JSONObject(data: response.data)
        return payload.dictionaries("Items")
            .map(JellyfinSeason.init(payload:))
            .sorted { lhs, rhs in
                (lhs.indexNumber ?? .max) < (rhs.indexNumber ?? .max)
            }
    }
    
    func loadEpisodes(accountID: UUID, seriesID: String, seasonID: String) async throws -> [JellyfinEpisode] {
        let response = try await authenticatedRequest(
            accountID: accountID,
            path: "/Shows/\(seriesID)/Episodes?userId=\(try userID(for: accountID))&seasonId=\(seasonID)&Fields=Overview,RunTimeTicks,UserData,SeriesName,SeasonName,IndexNumber,ParentIndexNumber,ImageTags"
        )
        let payload = try JSONObject(data: response.data)
        return payload.dictionaries("Items")
            .map(JellyfinEpisode.init(payload:))
            .sorted { lhs, rhs in
                let lhsIndex = lhs.indexNumber ?? .max
                let rhsIndex = rhs.indexNumber ?? .max
                if lhsIndex != rhsIndex {
                    return lhsIndex < rhsIndex
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
    
    func loadAdjacentEpisodes(accountID: UUID, episodeID: String) async throws -> [JellyfinEpisode] {
        let response = try await authenticatedRequest(
            accountID: accountID,
            path: "/Items?adjacentTo=\(episodeID)&limit=3&Fields=Overview,RunTimeTicks,UserData,SeriesName,SeasonName,IndexNumber,ParentIndexNumber,ImageTags"
        )
        let payload = try JSONObject(data: response.data)
        return payload.dictionaries("Items")
            .map(JellyfinEpisode.init(payload:))
            .sorted { lhs, rhs in
                let lhsSeason = lhs.parentIndexNumber ?? .max
                let rhsSeason = rhs.parentIndexNumber ?? .max
                if lhsSeason != rhsSeason {
                    return lhsSeason < rhsSeason
                }
                return (lhs.indexNumber ?? .max) < (rhs.indexNumber ?? .max)
            }
    }
    
    func createPlaybackSession(
        accountID: UUID,
        itemID: String,
        mediaSourceID: String? = nil
    ) async throws -> JellyfinPlaybackSession {
        let userID = try userID(for: accountID)
        let response = try await authenticatedRequest(
            accountID: accountID,
            path: "/Items/\(itemID)/PlaybackInfo?userId=\(userID)",
            method: "POST",
            body: [
                "UserId": userID,
                "EnableDirectPlay": true,
                "EnableDirectStream": true,
                "EnableTranscoding": false,
                "MediaSourceId": mediaSourceID as Any,
            ].compactMapValues { $0 }
        )
        let payload = try JSONObject(data: response.data)
        let sources = payload.dictionaries("MediaSources").map(JellyfinPlaybackMediaSource.init(payload:))
        let selectedSource = sources.first(where: { $0.id == mediaSourceID }) ?? sources.first
        let playSessionID = payload.string("PlaySessionId")
        let baseURL = response.route.normalizedURL
        let streamURL = resolvePlaybackURL(selectedSource?.directStreamPath, baseURL: baseURL)
            ?? buildDirectPlayURL(
                baseURL: baseURL,
                itemID: itemID,
                accessToken: response.profile.accessToken,
                mediaSourceID: selectedSource?.id,
                playSessionID: playSessionID
            )
        
        return JellyfinPlaybackSession(
            itemID: itemID,
            mediaSourceID: selectedSource?.id,
            playSessionID: playSessionID,
            streamURL: streamURL,
            mediaSources: sources
        )
    }
    
    private func ensureLoaded() async {
        guard !isLoaded else { return }
        defer { isLoaded = true }
        
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let data = defaults.data(forKey: Self.accountsKey),
           let decoded = try? decoder.decode([JellyfinAccountProfile].self, from: data)
        {
            accounts = decoded
        } else {
            accounts = []
        }
        
        if let rawActive = defaults.string(forKey: Self.activeAccountKey),
           let parsed = UUID(uuidString: rawActive),
           accounts.contains(where: { $0.id == parsed })
        {
            activeAccountID = parsed
        } else {
            activeAccountID = accounts.first?.id
        }
    }
    
    private func save() async {
        let defaults = UserDefaults.standard
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let data = try? encoder.encode(accounts) {
            defaults.set(data, forKey: Self.accountsKey)
        }
        defaults.set(activeAccountID?.uuidString, forKey: Self.activeAccountKey)
    }
    
    private func storeSnapshot() -> JellyfinStoreSnapshot {
        JellyfinStoreSnapshot(accounts: accounts, activeAccountID: activeAccountID)
    }
    
    private func userID(for accountID: UUID) throws -> String {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw JellyfinClientError.accountNotFound
        }
        return account.userID
    }
    
    private func fetchPublicInfo(baseURL: String) async throws -> JellyfinPublicInfo {
        let response = try await publicRequest(baseURL: baseURL, path: "/System/Info/Public")
        let payload = try JSONObject(data: response.data)
        guard let serverID = payload.string("Id") ?? payload.string("ServerId") else {
            throw JellyfinClientError.invalidResponse
        }
        return JellyfinPublicInfo(
            serverID: serverID,
            serverName: payload.string("ServerName") ?? "Jellyfin"
        )
    }
    
    private func authenticate(baseURL: String, username: String, password: String) async throws -> JellyfinAuthenticationResult {
        guard !username.isEmpty, !password.isEmpty else {
            throw JellyfinClientError.authenticationFailed
        }
        let response = try await rawRequest(
            baseURL: baseURL,
            path: "/Users/AuthenticateByName",
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "X-Emby-Authorization": authorizationHeader(token: nil),
            ],
            body: [
                "Username": username,
                "Pw": password,
            ]
        )
        let payload = try JSONObject(data: response.data)
        guard
            let accessToken = payload.string("AccessToken"),
            let user = payload.dictionary("User"),
            let userID = user.string("Id")
        else {
            throw JellyfinClientError.authenticationFailed
        }
        return JellyfinAuthenticationResult(userID: userID, accessToken: accessToken)
    }
    
    private func validateAuthenticatedRoute(
        account: JellyfinAccountProfile,
        route: JellyfinRoute
    ) async throws -> RawResponse {
        try await rawRequest(
            baseURL: route.normalizedURL,
            path: "/System/Info",
            headers: [
                "X-Emby-Authorization": authorizationHeader(token: account.accessToken),
            ]
        )
    }
    
    private func authenticatedRequest(
        accountID: UUID,
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> AuthenticatedResponse {
        await ensureLoaded()
        guard let accountIndex = accounts.firstIndex(where: { $0.id == accountID }) else {
            throw JellyfinClientError.accountNotFound
        }
        var account = accounts[accountIndex]
        let candidateRoutes = account.enabledRoutes
        guard !candidateRoutes.isEmpty else {
            throw JellyfinClientError.noAvailableRoute
        }
        
        var lastError: Error?
        for route in candidateRoutes where route.shouldRetry() {
            do {
                let raw = try await rawRequest(
                    baseURL: route.normalizedURL,
                    path: path,
                    method: method,
                    headers: [
                        "X-Emby-Authorization": authorizationHeader(token: account.accessToken),
                        "Content-Type": method.uppercased() == "GET" && body == nil ? nil : "application/json",
                    ].compactMapValues { $0 },
                    body: body
                )
                if raw.httpResponse.statusCode == 401 || raw.httpResponse.statusCode == 403 {
                    throw JellyfinClientError.authenticationExpired
                }
                account = account.markingRouteSuccess(route.id)
                accounts[accountIndex] = account
                activeAccountID = accountID
                await save()
                return AuthenticatedResponse(
                    data: raw.data,
                    httpResponse: raw.httpResponse,
                    profile: account,
                    route: route
                )
            } catch JellyfinClientError.authenticationExpired {
                throw JellyfinClientError.authenticationExpired
            } catch {
                lastError = error
                account = account.markingRouteFailure(route.id)
                accounts[accountIndex] = account
            }
        }
        
        await save()
        if let lastError {
            throw lastError
        }
        throw JellyfinClientError.noAvailableRoute
    }
    
    private func publicRequest(baseURL: String, path: String) async throws -> RawResponse {
        try await rawRequest(baseURL: baseURL, path: path, headers: [:])
    }
    
    private func rawRequest(
        baseURL: String,
        path: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> RawResponse {
        guard let url = buildURL(baseURL: baseURL, path: path) else {
            throw JellyfinClientError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let serverMessage = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw JellyfinClientError.authenticationExpired
            }
            throw JellyfinClientError.requestFailed(
                serverMessage?.nilIfBlank ?? "Jellyfin 请求失败：HTTP \(httpResponse.statusCode)"
            )
        }
        return RawResponse(data: data, httpResponse: httpResponse)
    }
    
    private func buildURL(baseURL: String, path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: "\(baseURL)\(normalizedPath)")
    }
    
    private func authorizationHeader(token: String?) -> String {
        let base = [
            "MediaBrowser Client=\"\(Self.clientName)\"",
            "Device=\"\(Self.clientDevice)\"",
            "DeviceId=\"\(Self.clientDeviceID)\"",
            "Version=\"\(Self.appVersion)\"",
        ].joined(separator: ", ")
        guard let token, !token.isEmpty else {
            return base
        }
        return "\(base), Token=\"\(token)\""
    }
    
    private func resolvePlaybackURL(_ rawPath: String?, baseURL: String) -> URL? {
        guard let rawPath = rawPath?.nilIfBlank else { return nil }
        if rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://") {
            return URL(string: rawPath)
        }
        let normalizedPath = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
        return URL(string: "\(baseURL)\(normalizedPath)")
    }
    
    private func buildDirectPlayURL(
        baseURL: String,
        itemID: String,
        accessToken: String,
        mediaSourceID: String?,
        playSessionID: String?
    ) -> URL {
        var components = URLComponents(string: "\(baseURL)/Videos/\(itemID)/stream")
        components?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: mediaSourceID ?? itemID),
            URLQueryItem(name: "PlaySessionId", value: playSessionID),
            URLQueryItem(name: "api_key", value: accessToken),
        ].filter { $0.value != nil }
        return components?.url ?? URL(string: "\(baseURL)/Videos/\(itemID)/stream")!
    }
    
    private func suggestedRouteName(for normalizedURL: String) -> String {
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
    
    private func JSONObject(data: Data) throws -> [String: Any] {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JellyfinClientError.invalidResponse
        }
        return payload
    }
}

private struct JellyfinPublicInfo {
    let serverID: String
    let serverName: String
}

private struct JellyfinAuthenticationResult {
    let userID: String
    let accessToken: String
}

private struct RawResponse {
    let data: Data
    let httpResponse: HTTPURLResponse
}

private struct AuthenticatedResponse {
    let data: Data
    let httpResponse: HTTPURLResponse
    let profile: JellyfinAccountProfile
    let route: JellyfinRoute
}

private enum JellyfinDateParser {
    private static let internet = ISO8601DateFormatter()
    private static let internetWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    static func parse(_ rawValue: String?) -> Date? {
        guard let rawValue = rawValue?.nilIfBlank else { return nil }
        return internetWithFractional.date(from: rawValue)
            ?? internet.date(from: rawValue)
    }
}

private extension Dictionary where Key == String, Value == Any {
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
