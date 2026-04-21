import Foundation
import XCTest
@testable import StarmineCore

private actor JellyfinURLProtocolState {
    static let shared = JellyfinURLProtocolState()

    private var requestHandler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    private var observedRequests: [URLRequest] = []

    func configure(
        handler: @escaping @Sendable (URLRequest) throws
            -> (HTTPURLResponse, Data)
    ) {
        requestHandler = handler
        observedRequests = []
    }

    func record(_ request: URLRequest) {
        observedRequests.append(request)
    }

    func handlerForCurrentTest()
        -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    {
        requestHandler
    }

    func requests() -> [URLRequest] {
        observedRequests
    }

    func reset() {
        requestHandler = nil
        observedRequests = []
    }
}

private final class JellyfinURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Task {
            await JellyfinURLProtocolState.shared.record(request)

            guard
                let handler = await JellyfinURLProtocolState.shared
                    .handlerForCurrentTest()
            else {
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.unknown)
                )
                return
            }

            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(
                    self,
                    didReceive: response,
                    cacheStoragePolicy: .notAllowed
                )
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

final class JellyfinClientTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "JellyfinClientTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    func testMigrationClearsLegacyAccountsWhenDeviceIDIsMissing()
        async throws
    {
        let legacyAccount = JellyfinAccountProfile(
            id: UUID(),
            serverID: "server-1",
            serverName: "Legacy Jellyfin",
            username: "alice",
            userID: "user-1",
            accessToken: "token-1",
            routes: [
                JellyfinRoute(
                    name: "Primary",
                    url: "https://primary.example.com",
                    priority: 0
                )
            ],
            lastSuccessfulRouteID: nil,
            lastConnectionAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        defaults.set(
            try encoder.encode([legacyAccount]),
            forKey: "starmine.jellyfin.accounts"
        )
        defaults.set(
            legacyAccount.id.uuidString,
            forKey: "starmine.jellyfin.active-account"
        )
        defaults.removeObject(forKey: "starmine.jellyfin.device-id")

        let client = makeClient()
        let snapshot = await client.snapshot()

        XCTAssertTrue(snapshot.accounts.isEmpty)
        XCTAssertNil(snapshot.activeAccountID)
    }

    func testDeviceIDIsPerInstallationAndStableAcrossClientInstances()
        async throws
    {
        let sharedSuiteName = "JellyfinClientTests.shared.\(UUID().uuidString)"
        let otherSuiteName = "JellyfinClientTests.other.\(UUID().uuidString)"
        let sharedDefaults = try XCTUnwrap(
            UserDefaults(suiteName: sharedSuiteName)
        )
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuiteName))
        sharedDefaults.removePersistentDomain(forName: sharedSuiteName)
        otherDefaults.removePersistentDomain(forName: otherSuiteName)
        defer {
            sharedDefaults.removePersistentDomain(forName: sharedSuiteName)
            otherDefaults.removePersistentDomain(forName: otherSuiteName)
        }

        let handler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) = {
            request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch (url.host, url.path) {
            case ("primary.example.com", "/System/Info/Public"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "Id": "server-1",
                        "ServerName": "Test Jellyfin",
                    ]
                )

            case ("primary.example.com", "/Users/AuthenticateByName"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "AccessToken": "token-1",
                        "User": ["Id": "user-1"],
                    ]
                )

            default:
                throw URLError(.unsupportedURL)
            }
        }

        await JellyfinURLProtocolState.shared.configure(handler: handler)

        let firstClient = makeClient(defaults: sharedDefaults)
        _ = try await firstClient.connect(
            serverURL: "https://primary.example.com",
            username: "alice",
            password: "secret",
            routeName: "Primary"
        )
        let firstObservedHeader = await latestAuthenticateAuthorizationHeader()
        let firstHeader = try XCTUnwrap(firstObservedHeader)
        let firstDeviceID = try XCTUnwrap(Self.deviceID(in: firstHeader))

        await JellyfinURLProtocolState.shared.configure(handler: handler)

        let secondClient = makeClient(defaults: sharedDefaults)
        _ = try await secondClient.connect(
            serverURL: "https://primary.example.com",
            username: "alice",
            password: "secret",
            routeName: "Primary"
        )
        let secondObservedHeader = await latestAuthenticateAuthorizationHeader()
        let secondHeader = try XCTUnwrap(secondObservedHeader)
        let secondDeviceID = try XCTUnwrap(Self.deviceID(in: secondHeader))

        await JellyfinURLProtocolState.shared.configure(handler: handler)

        let thirdClient = makeClient(defaults: otherDefaults)
        _ = try await thirdClient.connect(
            serverURL: "https://primary.example.com",
            username: "alice",
            password: "secret",
            routeName: "Primary"
        )
        let thirdObservedHeader = await latestAuthenticateAuthorizationHeader()
        let thirdHeader = try XCTUnwrap(thirdObservedHeader)
        let thirdDeviceID = try XCTUnwrap(Self.deviceID(in: thirdHeader))

        XCTAssertEqual(firstDeviceID, secondDeviceID)
        XCTAssertNotEqual(firstDeviceID, thirdDeviceID)
        XCTAssertNotEqual(firstDeviceID, "StarmineApple")
        XCTAssertTrue(firstDeviceID.hasPrefix("Starmine-"))

        await JellyfinURLProtocolState.shared.reset()
    }

    func testAutomaticRouteFallsBackToRealRequestWhenProbeTimesOut()
        async throws
    {
        await JellyfinURLProtocolState.shared.configure { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch (url.host, url.path) {
            case ("primary.example.com", "/System/Info/Public"),
                ("backup.example.com", "/System/Info/Public"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "Id": "server-1",
                        "ServerName": "Test Jellyfin",
                    ]
                )

            case ("primary.example.com", "/Users/AuthenticateByName"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "AccessToken": "token-1",
                        "User": ["Id": "user-1"],
                    ]
                )

            case (_, "/System/Info"):
                throw URLError(.timedOut)

            case ("primary.example.com", "/UserViews"):
                throw URLError(.timedOut)

            case ("backup.example.com", "/UserViews"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "Items": [
                            [
                                "Id": "library-1",
                                "Name": "Movies",
                                "CollectionType": "movies",
                            ]
                        ]
                    ]
                )

            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer {
            Task {
                await JellyfinURLProtocolState.shared.reset()
            }
        }

        let client = makeClient()
        let connectSnapshot = try await client.connect(
            serverURL: "https://primary.example.com",
            username: "alice",
            password: "secret",
            routeName: "Primary"
        )
        let accountID = try XCTUnwrap(connectSnapshot.activeAccountID)

        let routeSnapshot = try await client.addRoute(
            accountID: accountID,
            serverURL: "https://backup.example.com",
            routeName: "Backup"
        )
        let account = try XCTUnwrap(
            routeSnapshot.accounts.first(where: { $0.id == accountID })
        )
        let primaryRouteID = try XCTUnwrap(
            account.routes.first(where: {
                $0.normalizedURL == "https://primary.example.com"
            })?.id
        )
        let backupRouteID = try XCTUnwrap(
            account.routes.first(where: {
                $0.normalizedURL == "https://backup.example.com"
            })?.id
        )

        let libraries = try await client.loadLibraries(accountID: accountID)
        XCTAssertEqual(libraries.map(\.id), ["library-1"])

        let snapshot = await client.snapshot()
        let updatedAccount = try XCTUnwrap(
            snapshot.accounts.first(where: { $0.id == accountID })
        )

        XCTAssertEqual(updatedAccount.lastSuccessfulRouteID, backupRouteID)
        XCTAssertEqual(updatedAccount.activeRoute?.id, backupRouteID)
        XCTAssertEqual(
            updatedAccount.routes.first(where: { $0.id == primaryRouteID })?
                .failureCount,
            1
        )
        XCTAssertEqual(
            updatedAccount.routes.first(where: { $0.id == backupRouteID })?
                .failureCount,
            0
        )

        let observedRequests = await JellyfinURLProtocolState.shared.requests()
        XCTAssertTrue(
            observedRequests.contains(where: { request in
                request.url?.host == "backup.example.com"
                    && request.url?.path == "/UserViews"
            })
        )
    }

    func testSingleAutomaticRouteSkipsProbeBeforeAuthenticatedRequest()
        async throws
    {
        await JellyfinURLProtocolState.shared.configure { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch (url.host, url.path) {
            case ("primary.example.com", "/System/Info/Public"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "Id": "server-1",
                        "ServerName": "Test Jellyfin",
                    ]
                )

            case ("primary.example.com", "/Users/AuthenticateByName"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "AccessToken": "token-1",
                        "User": ["Id": "user-1"],
                    ]
                )

            case ("primary.example.com", "/UserViews"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "Items": [
                            [
                                "Id": "library-1",
                                "Name": "Movies",
                                "CollectionType": "movies",
                            ]
                        ]
                    ]
                )

            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer {
            Task {
                await JellyfinURLProtocolState.shared.reset()
            }
        }

        let client = makeClient()
        let connectSnapshot = try await client.connect(
            serverURL: "https://primary.example.com",
            username: "alice",
            password: "secret",
            routeName: "Primary"
        )
        let accountID = try XCTUnwrap(connectSnapshot.activeAccountID)

        let libraries = try await client.loadLibraries(accountID: accountID)
        XCTAssertEqual(libraries.map(\.id), ["library-1"])

        let observedRequests = await JellyfinURLProtocolState.shared.requests()
        XCTAssertFalse(
            observedRequests.contains(where: { request in
                request.url?.host == "primary.example.com"
                    && request.url?.path == "/System/Info"
            })
        )
    }

    func testUseAutomaticRouteSelectionPersistsWithoutReconciliationSave()
        async throws
    {
        await JellyfinURLProtocolState.shared.configure { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch (url.host, url.path) {
            case ("primary.example.com", "/System/Info/Public"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "Id": "server-1",
                        "ServerName": "Test Jellyfin",
                    ]
                )

            case ("primary.example.com", "/Users/AuthenticateByName"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "AccessToken": "token-1",
                        "User": ["Id": "user-1"],
                    ]
                )

            case ("primary.example.com", "/System/Info"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "Version": "10.9.0",
                    ]
                )

            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer {
            Task {
                await JellyfinURLProtocolState.shared.reset()
            }
        }

        let client = makeClient()
        let connectSnapshot = try await client.connect(
            serverURL: "https://primary.example.com",
            username: "alice",
            password: "secret",
            routeName: "Primary"
        )
        let accountID = try XCTUnwrap(connectSnapshot.activeAccountID)
        let routeID = try XCTUnwrap(
            connectSnapshot.accounts.first(where: { $0.id == accountID })?
                .routes.first?.id
        )

        _ = try await client.switchRoute(
            accountID: accountID,
            routeID: routeID
        )
        let automaticSnapshot = try await client.useAutomaticRouteSelection(
            accountID: accountID
        )
        let automaticAccount = try XCTUnwrap(
            automaticSnapshot.accounts.first(where: { $0.id == accountID })
        )
        XCTAssertTrue(automaticAccount.usesAutomaticRouteSelection)
        XCTAssertNil(automaticAccount.manualRouteID)

        let reloadedClient = makeClient()
        let reloadedSnapshot = await reloadedClient.snapshot()
        let reloadedAccount = try XCTUnwrap(
            reloadedSnapshot.accounts.first(where: { $0.id == accountID })
        )
        XCTAssertTrue(reloadedAccount.usesAutomaticRouteSelection)
        XCTAssertNil(reloadedAccount.manualRouteID)
    }

    func testUpdateRoutePriorityPersistsForAutomaticSingleRouteAccount()
        async throws
    {
        await JellyfinURLProtocolState.shared.configure { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch (url.host, url.path) {
            case ("primary.example.com", "/System/Info/Public"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "Id": "server-1",
                        "ServerName": "Test Jellyfin",
                    ]
                )

            case ("primary.example.com", "/Users/AuthenticateByName"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "AccessToken": "token-1",
                        "User": ["Id": "user-1"],
                    ]
                )

            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer {
            Task {
                await JellyfinURLProtocolState.shared.reset()
            }
        }

        let client = makeClient()
        let connectSnapshot = try await client.connect(
            serverURL: "https://primary.example.com",
            username: "alice",
            password: "secret",
            routeName: "Primary"
        )
        let accountID = try XCTUnwrap(connectSnapshot.activeAccountID)
        let routeID = try XCTUnwrap(
            connectSnapshot.accounts.first(where: { $0.id == accountID })?
                .routes.first?.id
        )

        let updatedSnapshot = try await client.updateRoutePriority(
            accountID: accountID,
            routeID: routeID,
            priority: 7
        )
        let updatedAccount = try XCTUnwrap(
            updatedSnapshot.accounts.first(where: { $0.id == accountID })
        )
        XCTAssertEqual(
            updatedAccount.routes.first(where: { $0.id == routeID })?.priority,
            7
        )

        let reloadedClient = makeClient()
        let reloadedSnapshot = await reloadedClient.snapshot()
        let reloadedAccount = try XCTUnwrap(
            reloadedSnapshot.accounts.first(where: { $0.id == accountID })
        )
        XCTAssertEqual(
            reloadedAccount.routes.first(where: { $0.id == routeID })?.priority,
            7
        )
    }

    func testRemoveRouteDeletesAccountWhenLastRouteRemoved() async throws {
        await JellyfinURLProtocolState.shared.configure { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch (url.host, url.path) {
            case ("primary.example.com", "/System/Info/Public"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "Id": "server-1",
                        "ServerName": "Test Jellyfin",
                    ]
                )

            case ("primary.example.com", "/Users/AuthenticateByName"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "AccessToken": "token-1",
                        "User": ["Id": "user-1"],
                    ]
                )

            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer {
            Task {
                await JellyfinURLProtocolState.shared.reset()
            }
        }

        let client = makeClient()
        let connectSnapshot = try await client.connect(
            serverURL: "https://primary.example.com",
            username: "alice",
            password: "secret",
            routeName: "Primary"
        )
        let accountID = try XCTUnwrap(connectSnapshot.activeAccountID)
        let routeID = try XCTUnwrap(
            connectSnapshot.accounts.first(where: { $0.id == accountID })?
                .routes.first?.id
        )

        let updatedSnapshot = try await client.removeRoute(
            accountID: accountID,
            routeID: routeID
        )

        XCTAssertTrue(updatedSnapshot.accounts.isEmpty)
        XCTAssertNil(updatedSnapshot.activeAccountID)

        let reloadedClient = makeClient()
        let reloadedSnapshot = await reloadedClient.snapshot()
        XCTAssertTrue(reloadedSnapshot.accounts.isEmpty)
        XCTAssertNil(reloadedSnapshot.activeAccountID)
    }

    func testRemoveRouteClearsManualSelectionWhenRemovingManualRoute()
        async throws
    {
        await JellyfinURLProtocolState.shared.configure { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch (url.host, url.path) {
            case ("primary.example.com", "/System/Info/Public"),
                ("backup.example.com", "/System/Info/Public"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "Id": "server-1",
                        "ServerName": "Test Jellyfin",
                    ]
                )

            case ("primary.example.com", "/Users/AuthenticateByName"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "AccessToken": "token-1",
                        "User": ["Id": "user-1"],
                    ]
                )

            case ("backup.example.com", "/System/Info"):
                return try Self.jsonResponse(
                    url: url,
                    body: [
                        "Id": "server-1",
                        "ServerName": "Test Jellyfin",
                    ]
                )

            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer {
            Task {
                await JellyfinURLProtocolState.shared.reset()
            }
        }

        let client = makeClient()
        let connectSnapshot = try await client.connect(
            serverURL: "https://primary.example.com",
            username: "alice",
            password: "secret",
            routeName: "Primary"
        )
        let accountID = try XCTUnwrap(connectSnapshot.activeAccountID)
        let routeSnapshot = try await client.addRoute(
            accountID: accountID,
            serverURL: "https://backup.example.com",
            routeName: "Backup"
        )
        let account = try XCTUnwrap(
            routeSnapshot.accounts.first(where: { $0.id == accountID })
        )
        let primaryRouteID = try XCTUnwrap(
            account.routes.first(where: {
                $0.normalizedURL == "https://primary.example.com"
            })?.id
        )
        let backupRouteID = try XCTUnwrap(
            account.routes.first(where: {
                $0.normalizedURL == "https://backup.example.com"
            })?.id
        )

        _ = try await client.switchRoute(
            accountID: accountID,
            routeID: backupRouteID
        )

        let updatedSnapshot = try await client.removeRoute(
            accountID: accountID,
            routeID: backupRouteID
        )
        let updatedAccount = try XCTUnwrap(
            updatedSnapshot.accounts.first(where: { $0.id == accountID })
        )

        XCTAssertNil(updatedAccount.manualRouteID)
        XCTAssertEqual(updatedAccount.routes.map(\.id), [primaryRouteID])
        XCTAssertEqual(updatedAccount.activeRoute?.id, primaryRouteID)

        let reloadedClient = makeClient()
        let reloadedSnapshot = await reloadedClient.snapshot()
        let reloadedAccount = try XCTUnwrap(
            reloadedSnapshot.accounts.first(where: { $0.id == accountID })
        )
        XCTAssertNil(reloadedAccount.manualRouteID)
        XCTAssertEqual(reloadedAccount.routes.map(\.id), [primaryRouteID])
        XCTAssertEqual(reloadedAccount.activeRoute?.id, primaryRouteID)
    }

    private func latestAuthenticateAuthorizationHeader() async -> String? {
        let observedRequests = await JellyfinURLProtocolState.shared.requests()
        return observedRequests.reversed().first(where: { request in
            request.url?.path == "/Users/AuthenticateByName"
        })?.value(forHTTPHeaderField: "X-Emby-Authorization")
    }

    private func makeClient(defaults: UserDefaults? = nil) -> JellyfinClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JellyfinURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return JellyfinClient(session: session, defaults: defaults ?? self.defaults)
    }

    private static func jsonResponse(
        url: URL,
        statusCode: Int = 200,
        body: [String: Any]
    ) throws -> (HTTPURLResponse, Data) {
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (response, data)
    }

    private static func deviceID(in authorizationHeader: String) -> String? {
        let marker = "DeviceId=\""
        guard let range = authorizationHeader.range(of: marker) else {
            return nil
        }
        let valueStart = range.upperBound
        guard let valueEnd = authorizationHeader[valueStart...].firstIndex(of: "\"")
        else {
            return nil
        }
        return String(authorizationHeader[valueStart..<valueEnd])
    }
}
