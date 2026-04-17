import Foundation

protocol JellyfinClientProtocol {
    func snapshot() async -> JellyfinStoreSnapshot
    func connect(
        serverURL: String,
        username: String,
        password: String,
        routeName: String?
    ) async throws -> JellyfinStoreSnapshot
    func setActiveAccount(_ accountID: UUID) async throws
        -> JellyfinStoreSnapshot
    func removeAccount(_ accountID: UUID) async throws -> JellyfinStoreSnapshot
    func addRoute(accountID: UUID, serverURL: String, routeName: String?)
        async throws -> JellyfinStoreSnapshot
    func switchRoute(accountID: UUID, routeID: UUID) async throws
        -> JellyfinStoreSnapshot
    func rememberSelectedLibrary(accountID: UUID, libraryID: String?) async
        -> JellyfinStoreSnapshot
    func loadLibraries(accountID: UUID) async throws -> [JellyfinLibrary]
    func loadLibraryItems(accountID: UUID, libraryID: String) async throws
        -> [JellyfinMediaItem]
    func loadSeasons(accountID: UUID, seriesID: String) async throws
        -> [JellyfinSeason]
    func loadEpisodes(accountID: UUID, seriesID: String, seasonID: String)
        async throws -> [JellyfinEpisode]
    func loadAdjacentEpisodes(accountID: UUID, episodeID: String) async throws
        -> [JellyfinEpisode]
    func loadResumeItems(accountID: UUID, limit: Int) async throws
        -> [JellyfinHomeItem]
    func loadRecentItems(accountID: UUID, limit: Int) async throws
        -> [JellyfinHomeItem]
    func loadNextUp(accountID: UUID, limit: Int) async throws
        -> [JellyfinHomeItem]
    func loadRecommendedItems(accountID: UUID, limit: Int) async throws
        -> [JellyfinHomeItem]
    func loadUserData(accountID: UUID, itemID: String) async throws
        -> JellyfinUserData
    func createPlaybackSession(
        accountID: UUID,
        itemID: String,
        mediaSourceID: String?
    ) async throws -> JellyfinPlaybackSession
    func reportPlaybackStarted(
        accountID: UUID,
        session: JellyfinPlaybackSession,
        positionSeconds: Double,
        isPaused: Bool
    ) async throws
    func reportPlaybackProgress(
        accountID: UUID,
        session: JellyfinPlaybackSession,
        positionSeconds: Double,
        isPaused: Bool
    ) async throws
    func reportPlaybackStopped(
        accountID: UUID,
        session: JellyfinPlaybackSession,
        positionSeconds: Double,
        isPaused: Bool,
        finished: Bool
    ) async throws
    func markPlayed(accountID: UUID, itemID: String) async throws
    func markUnplayed(accountID: UUID, itemID: String) async throws
}

actor JellyfinClient: JellyfinClientProtocol {
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

        let normalizedURL = JellyfinURLTools.normalize(serverURL)
        let publicInfo = try await fetchPublicInfo(baseURL: normalizedURL)
        let auth = try await authenticate(
            baseURL: normalizedURL,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )

        if let conflicting = accounts.first(where: { profile in
            profile.routes.contains(where: { $0.normalizedURL == normalizedURL }
            ) && profile.serverID != publicInfo.serverID
        }) {
            throw JellyfinClientError.serverConflict(
                "该地址已经绑定到另一台 Jellyfin 服务器：\(conflicting.serverName)。"
            )
        }

        if let accountIndex = accounts.firstIndex(where: {
            $0.serverID == publicInfo.serverID
                && $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) {
            var account = accounts[accountIndex]
            if !account.routes.contains(where: {
                $0.normalizedURL == normalizedURL
            }) {
                let nextPriority =
                    (account.routes.map(\.priority).max() ?? -1) + 1
                account.routes.append(
                    JellyfinRoute(
                        name: routeName?.nilIfBlank
                            ?? JellyfinURLTools.suggestedRouteName(
                                for: normalizedURL
                            ),
                        url: normalizedURL,
                        priority: nextPriority
                    )
                )
            }
            account.serverName = publicInfo.serverName
            account.userID = auth.userID
            account.accessToken = auth.accessToken
            if let route = account.routes.first(where: {
                $0.normalizedURL == normalizedURL
            }) {
                account = account.markingRouteSuccess(route.id)
            }
            accounts[accountIndex] = account
            activeAccountID = account.id
            await save()
            return storeSnapshot()
        }

        let route = JellyfinRoute(
            name: routeName?.nilIfBlank
                ?? JellyfinURLTools.suggestedRouteName(for: normalizedURL),
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

    func setActiveAccount(_ accountID: UUID) async throws
        -> JellyfinStoreSnapshot
    {
        await ensureLoaded()
        guard accounts.contains(where: { $0.id == accountID }) else {
            throw JellyfinClientError.accountNotFound
        }
        activeAccountID = accountID
        await save()
        return storeSnapshot()
    }

    func removeAccount(_ accountID: UUID) async throws -> JellyfinStoreSnapshot
    {
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
        guard
            let accountIndex = accounts.firstIndex(where: { $0.id == accountID }
            )
        else {
            throw JellyfinClientError.accountNotFound
        }

        let normalizedURL = JellyfinURLTools.normalize(serverURL)
        let publicInfo = try await fetchPublicInfo(baseURL: normalizedURL)
        var account = accounts[accountIndex]

        guard publicInfo.serverID == account.serverID else {
            throw JellyfinClientError.serverConflict(
                "这条地址属于另一台 Jellyfin 服务器，不能添加到当前账号。"
            )
        }

        if account.routes.contains(where: { $0.normalizedURL == normalizedURL })
        {
            return storeSnapshot()
        }

        let nextPriority = (account.routes.map(\.priority).max() ?? -1) + 1
        account.routes.append(
            JellyfinRoute(
                name: routeName?.nilIfBlank
                    ?? JellyfinURLTools.suggestedRouteName(for: normalizedURL),
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
        guard
            let accountIndex = accounts.firstIndex(where: { $0.id == accountID }
            )
        else {
            throw JellyfinClientError.accountNotFound
        }
        let account = accounts[accountIndex]
        guard let route = account.routes.first(where: { $0.id == routeID })
        else {
            throw JellyfinClientError.routeNotFound
        }

        do {
            _ = try await validateAuthenticatedRoute(
                account: account,
                route: route
            )
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

    func rememberSelectedLibrary(accountID: UUID, libraryID: String?) async
        -> JellyfinStoreSnapshot
    {
        await ensureLoaded()
        guard
            let accountIndex = accounts.firstIndex(where: { $0.id == accountID }
            )
        else {
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
        let payload = try jsonObject(data: response.data)
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
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }

        if let accountIndex = accounts.firstIndex(where: { $0.id == accountID })
        {
            if let currentLibraryID = accounts[accountIndex]
                .lastSelectedLibraryID,
                libraries.contains(where: { $0.id == currentLibraryID })
            {
                // Keep existing selection.
            } else {
                accounts[accountIndex].lastSelectedLibraryID =
                    libraries.first?.id
                await save()
            }
        }

        return libraries
    }

    func loadLibraryItems(accountID: UUID, libraryID: String) async throws
        -> [JellyfinMediaItem]
    {
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

        let response = try await authenticatedRequest(
            accountID: accountID,
            path: path
        )
        let payload = try jsonObject(data: response.data)
        return payload.dictionaries("Items")
            .map(JellyfinMediaItem.init(payload:))
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
    }

    func loadSeasons(accountID: UUID, seriesID: String) async throws
        -> [JellyfinSeason]
    {
        let response = try await authenticatedRequest(
            accountID: accountID,
            path:
                "/Shows/\(seriesID)/Seasons?userId=\(try userID(for: accountID))&Fields=ImageTags,SeriesName,IndexNumber"
        )
        let payload = try jsonObject(data: response.data)
        return payload.dictionaries("Items")
            .map(JellyfinSeason.init(payload:))
            .sorted { lhs, rhs in
                (lhs.indexNumber ?? .max) < (rhs.indexNumber ?? .max)
            }
    }

    func loadEpisodes(accountID: UUID, seriesID: String, seasonID: String)
        async throws -> [JellyfinEpisode]
    {
        let response = try await authenticatedRequest(
            accountID: accountID,
            path:
                "/Shows/\(seriesID)/Episodes?userId=\(try userID(for: accountID))&seasonId=\(seasonID)&Fields=Overview,RunTimeTicks,UserData,SeriesName,SeasonName,IndexNumber,ParentIndexNumber,ImageTags"
        )
        let payload = try jsonObject(data: response.data)
        return payload.dictionaries("Items")
            .map(JellyfinEpisode.init(payload:))
            .sorted { lhs, rhs in
                let lhsIndex = lhs.indexNumber ?? .max
                let rhsIndex = rhs.indexNumber ?? .max
                if lhsIndex != rhsIndex {
                    return lhsIndex < rhsIndex
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
    }

    func loadAdjacentEpisodes(accountID: UUID, episodeID: String) async throws
        -> [JellyfinEpisode]
    {
        let response = try await authenticatedRequest(
            accountID: accountID,
            path:
                "/Items?adjacentTo=\(episodeID)&limit=3&Fields=Overview,RunTimeTicks,UserData,SeriesName,SeasonName,IndexNumber,ParentIndexNumber,ImageTags"
        )
        let payload = try jsonObject(data: response.data)
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

    func loadResumeItems(accountID: UUID, limit: Int = 18) async throws
        -> [JellyfinHomeItem]
    {
        let response = try await authenticatedRequest(
            accountID: accountID,
            path:
                "/Items/Resume?userId=\(try userID(for: accountID))&Limit=\(limit)&MediaTypes=Video&Fields=\(homeItemFields)"
        )
        let payload = try jsonObject(data: response.data)
        return payload.dictionaries("Items").map(
            JellyfinHomeItem.init(payload:)
        )
    }

    func loadRecentItems(accountID: UUID, limit: Int = 18) async throws
        -> [JellyfinHomeItem]
    {
        let userID = try userID(for: accountID)
        let response = try await authenticatedRequest(
            accountID: accountID,
            path:
                "/Users/\(userID)/Items?Recursive=true&IncludeItemTypes=Episode,Movie,Video&SortBy=DatePlayed&SortOrder=Descending&Filters=IsPlayed&Limit=\(limit)&Fields=\(homeItemFields)"
        )
        let payload = try jsonObject(data: response.data)
        return payload.dictionaries("Items").map(
            JellyfinHomeItem.init(payload:)
        )
    }

    func loadNextUp(accountID: UUID, limit: Int = 18) async throws
        -> [JellyfinHomeItem]
    {
        let response = try await authenticatedRequest(
            accountID: accountID,
            path:
                "/Shows/NextUp?userId=\(try userID(for: accountID))&Limit=\(limit)&Fields=\(homeItemFields)"
        )
        let payload = try jsonObject(data: response.data)
        return payload.dictionaries("Items").map(
            JellyfinHomeItem.init(payload:)
        )
    }

    func loadRecommendedItems(accountID: UUID, limit: Int = 18) async throws
        -> [JellyfinHomeItem]
    {
        let response = try await authenticatedRequest(
            accountID: accountID,
            path:
                "/Suggestions?userId=\(try userID(for: accountID))&MediaType=Video&Type=Movie,Series&Limit=\(limit)&Fields=\(homeItemFields)"
        )
        let payload = try jsonObject(data: response.data)
        return payload.dictionaries("Items").map(
            JellyfinHomeItem.init(payload:)
        )
    }

    func loadUserData(accountID: UUID, itemID: String) async throws
        -> JellyfinUserData
    {
        let userID = try userID(for: accountID)
        let response = try await authenticatedRequest(
            accountID: accountID,
            path: "/Users/\(userID)/Items/\(itemID)?Fields=UserData"
        )
        let payload = try jsonObject(data: response.data)
        return payload.dictionary("UserData").map(
            JellyfinUserData.init(payload:)
        )
            ?? JellyfinUserData()
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
        let payload = try jsonObject(data: response.data)
        let sources = payload.dictionaries("MediaSources").map {
            sourcePayload in
            let source = JellyfinPlaybackMediaSource(payload: sourcePayload)
            var resolvedSource = source
            resolvedSource.subtitleStreams = source.subtitleStreams.map {
                $0.resolving(
                    baseURL: response.route.normalizedURL,
                    accessToken: response.profile.accessToken,
                    itemID: itemID,
                    mediaSourceID: source.id
                )
            }
            return resolvedSource
        }
        let selectedSource =
            sources.first(where: { $0.id == mediaSourceID }) ?? sources.first
        let playSessionID = payload.string("PlaySessionId")
        let baseURL = response.route.normalizedURL
        let streamURL =
            resolvePlaybackURL(
                selectedSource?.directStreamPath,
                baseURL: baseURL,
                accessToken: response.profile.accessToken
            )
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

    func reportPlaybackStarted(
        accountID: UUID,
        session: JellyfinPlaybackSession,
        positionSeconds: Double,
        isPaused: Bool
    ) async throws {
        _ = try await authenticatedRequest(
            accountID: accountID,
            path: "/Sessions/Playing",
            method: "POST",
            body: playbackInfoBody(
                session: session,
                positionSeconds: positionSeconds,
                isPaused: isPaused
            )
        )
    }

    func reportPlaybackProgress(
        accountID: UUID,
        session: JellyfinPlaybackSession,
        positionSeconds: Double,
        isPaused: Bool
    ) async throws {
        _ = try await authenticatedRequest(
            accountID: accountID,
            path: "/Sessions/Playing/Progress",
            method: "POST",
            body: playbackInfoBody(
                session: session,
                positionSeconds: positionSeconds,
                isPaused: isPaused
            )
        )
    }

    func reportPlaybackStopped(
        accountID: UUID,
        session: JellyfinPlaybackSession,
        positionSeconds: Double,
        isPaused: Bool,
        finished: Bool
    ) async throws {
        var body = playbackInfoBody(
            session: session,
            positionSeconds: positionSeconds,
            isPaused: isPaused
        )
        body["Failed"] = false
        _ = try await authenticatedRequest(
            accountID: accountID,
            path: "/Sessions/Playing/Stopped",
            method: "POST",
            body: body
        )
    }

    func markPlayed(accountID: UUID, itemID: String) async throws {
        _ = try await authenticatedRequest(
            accountID: accountID,
            path: "/UserPlayedItems/\(itemID)",
            method: "POST"
        )
    }

    func markUnplayed(accountID: UUID, itemID: String) async throws {
        _ = try await authenticatedRequest(
            accountID: accountID,
            path: "/UserPlayedItems/\(itemID)",
            method: "DELETE"
        )
    }

    private func ensureLoaded() async {
        guard !isLoaded else { return }
        defer { isLoaded = true }

        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let data = defaults.data(forKey: Self.accountsKey),
            let decoded = try? decoder.decode(
                [JellyfinAccountProfile].self,
                from: data
            )
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
        JellyfinStoreSnapshot(
            accounts: accounts,
            activeAccountID: activeAccountID
        )
    }

    private func userID(for accountID: UUID) throws -> String {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw JellyfinClientError.accountNotFound
        }
        return account.userID
    }

    private func fetchPublicInfo(baseURL: String) async throws
        -> JellyfinPublicInfo
    {
        let response = try await publicRequest(
            baseURL: baseURL,
            path: "/System/Info/Public"
        )
        let payload = try jsonObject(data: response.data)
        guard let serverID = payload.string("Id") ?? payload.string("ServerId")
        else {
            throw JellyfinClientError.invalidResponse
        }
        return JellyfinPublicInfo(
            serverID: serverID,
            serverName: payload.string("ServerName") ?? "Jellyfin"
        )
    }

    private func authenticate(
        baseURL: String,
        username: String,
        password: String
    ) async throws -> JellyfinAuthenticationResult {
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
        let payload = try jsonObject(data: response.data)
        guard
            let accessToken = payload.string("AccessToken"),
            let user = payload.dictionary("User"),
            let userID = user.string("Id")
        else {
            throw JellyfinClientError.authenticationFailed
        }
        return JellyfinAuthenticationResult(
            userID: userID,
            accessToken: accessToken
        )
    }

    private func validateAuthenticatedRoute(
        account: JellyfinAccountProfile,
        route: JellyfinRoute
    ) async throws -> RawResponse {
        try await rawRequest(
            baseURL: route.normalizedURL,
            path: "/System/Info",
            headers: [
                "X-Emby-Authorization": authorizationHeader(
                    token: account.accessToken
                )
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
        guard
            let accountIndex = accounts.firstIndex(where: { $0.id == accountID }
            )
        else {
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
                        "X-Emby-Authorization": authorizationHeader(
                            token: account.accessToken
                        ),
                        "Content-Type": method.uppercased() == "GET"
                            && body == nil ? nil : "application/json",
                    ].compactMapValues { $0 },
                    body: body
                )
                if raw.httpResponse.statusCode == 401
                    || raw.httpResponse.statusCode == 403
                {
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

    private func publicRequest(baseURL: String, path: String) async throws
        -> RawResponse
    {
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
        guard (200..<300).contains(httpResponse.statusCode) else {
            let serverMessage = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403
            {
                throw JellyfinClientError.authenticationExpired
            }
            throw JellyfinClientError.requestFailed(
                serverMessage?.nilIfBlank
                    ?? "Jellyfin 请求失败：HTTP \(httpResponse.statusCode)"
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

    private func resolvePlaybackURL(
        _ rawPath: String?,
        baseURL: String,
        accessToken: String
    ) -> URL? {
        JellyfinURLTools.resolve(
            rawPath,
            baseURL: baseURL,
            accessToken: accessToken
        )
    }

    private func buildDirectPlayURL(
        baseURL: String,
        itemID: String,
        accessToken: String,
        mediaSourceID: String?,
        playSessionID: String?
    ) -> URL {
        var components = URLComponents(
            string: "\(baseURL)/Videos/\(itemID)/stream"
        )
        components?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: mediaSourceID ?? itemID),
            URLQueryItem(name: "PlaySessionId", value: playSessionID),
            URLQueryItem(name: "api_key", value: accessToken),
        ].filter { $0.value != nil }
        return components?.url ?? URL(
            string: "\(baseURL)/Videos/\(itemID)/stream"
        )!
    }

    private var homeItemFields: String {
        [
            "Overview",
            "ProductionYear",
            "CommunityRating",
            "RunTimeTicks",
            "UserData",
            "ImageTags",
            "BackdropImageTags",
            "SeriesId",
            "SeriesName",
            "SeasonId",
            "SeasonName",
            "IndexNumber",
            "ParentIndexNumber",
            "DateCreated",
        ]
        .joined(separator: ",")
    }

    private func playbackInfoBody(
        session: JellyfinPlaybackSession,
        positionSeconds: Double,
        isPaused: Bool
    ) -> [String: Any] {
        let mediaSource =
            session.mediaSources.first(where: { $0.id == session.mediaSourceID }
            )
            ?? session.mediaSources.first

        var body: [String: Any] = [
            "CanSeek": true,
            "IsPaused": isPaused,
            "ItemId": session.itemID,
            "PlayMethod": playbackMethod(for: mediaSource),
            "PositionTicks": max(0, Int64(positionSeconds * 10_000_000.0)),
        ]

        if let mediaSourceID = session.mediaSourceID ?? mediaSource?.id {
            body["MediaSourceId"] = mediaSourceID
        }
        if let playSessionID = session.playSessionID {
            body["PlaySessionId"] = playSessionID
        }

        return body
    }

    private func playbackMethod(for mediaSource: JellyfinPlaybackMediaSource?)
        -> String
    {
        if mediaSource?.directStreamPath?.nilIfBlank != nil {
            return "DirectStream"
        }
        return "DirectPlay"
    }

    private func jsonObject(data: Data) throws -> [String: Any] {
        guard
            let payload = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
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
