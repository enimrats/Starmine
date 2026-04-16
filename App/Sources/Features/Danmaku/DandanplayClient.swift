import CryptoKit
import Foundation

enum DandanplayClientError: LocalizedError {
    case invalidResponse
    case missingSecret
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "弹弹play 返回了无法解析的数据。"
        case .missingSecret:
            return "没有拿到可用的 appSecret。"
        case let .requestFailed(message):
            return message
        }
    }
}

protocol DandanplayClientProtocol {
    func searchAnime(keyword: String) async throws -> [AnimeSearchResult]
    func loadEpisodes(for animeID: Int) async throws -> [AnimeEpisode]
    func loadDanmaku(episodeID: Int, chConvert: Int) async throws
        -> [DanmakuComment]
}

actor DandanplayClient: DandanplayClientProtocol {
    static let appID = "nipaplayv1"
    static let userAgent = "NipaPlayApple/0.1"

    private let apiBaseURL = URL(string: "https://api.dandanplay.net")!
    private let secretServers = [
        URL(string: "https://nipaplay.aimes-soft.com")!,
        URL(string: "https://kurisu.aimes-soft.com")!,
    ]
    private let danmakuProxyURL = URL(
        string: "https://nipaplay.aimes-soft.com/danmaku_proxy.php"
    )!

    private var appSecret: String?

    func searchAnime(keyword: String) async throws -> [AnimeSearchResult] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let data = try await requestData(
            apiPath: "/api/v2/search/anime",
            query: [URLQueryItem(name: "keyword", value: trimmed)]
        )
        guard
            let payload = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let rawResults = payload["animes"] as? [[String: Any]]
        else {
            throw DandanplayClientError.invalidResponse
        }

        return rawResults.compactMap { item in
            guard let animeID = item["animeId"] as? Int else { return nil }
            let imageURL = (item["imageUrl"] as? String).flatMap(
                URL.init(string:)
            )
            return AnimeSearchResult(
                id: animeID,
                title: (item["animeTitle"] as? String)
                    ?? (item["title"] as? String) ?? "未命名条目",
                typeDescription: (item["typeDescription"] as? String) ?? "",
                imageURL: imageURL,
                episodeCount: item["episodeCount"] as? Int
            )
        }
    }

    func loadEpisodes(for animeID: Int) async throws -> [AnimeEpisode] {
        let data = try await requestData(apiPath: "/api/v2/bangumi/\(animeID)")
        guard
            let payload = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw DandanplayClientError.invalidResponse
        }

        let rawEpisodes: [[String: Any]]
        if let bangumi = payload["bangumi"] as? [String: Any],
            let nested = bangumi["episodes"] as? [[String: Any]]
        {
            rawEpisodes = nested
        } else if let flat = payload["episodes"] as? [[String: Any]] {
            rawEpisodes = flat
        } else {
            rawEpisodes = []
        }

        return rawEpisodes.compactMap { item in
            guard let episodeID = item["episodeId"] as? Int else { return nil }
            return AnimeEpisode(
                id: episodeID,
                number: item["episodeNumber"] as? Int,
                title: (item["episodeTitle"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                    ?? "第 \(item["episodeNumber"] as? Int ?? 0) 话"
            )
        }
    }

    func loadDanmaku(episodeID: Int, chConvert: Int = 0) async throws
        -> [DanmakuComment]
    {
        let apiPath = "/api/v2/comment/\(episodeID)"
        let query = [
            URLQueryItem(name: "withRelated", value: "true"),
            URLQueryItem(name: "chConvert", value: String(chConvert)),
        ]

        do {
            let data = try await requestData(apiPath: apiPath, query: query)
            return try parseDanmaku(from: data)
        } catch {
            let data = try await requestData(
                apiPath: apiPath,
                query: query,
                useProxy: true
            )
            return try parseDanmaku(from: data)
        }
    }

    static func decodeEncryptedAppSecret(_ input: String) -> String {
        let atbashed = input.map { character -> Character in
            guard let scalar = character.unicodeScalars.first else {
                return character
            }
            switch scalar.value {
            case 65...90:
                return Character(UnicodeScalar(65 + 25 - (scalar.value - 65))!)
            case 97...122:
                return Character(UnicodeScalar(97 + 25 - (scalar.value - 97))!)
            default:
                return character
            }
        }

        let shifted: String
        if atbashed.count >= 5 {
            let first = String(atbashed.prefix(1))
            let body = String(atbashed.dropFirst().dropLast(4))
            let tail = String(atbashed.suffix(4))
            shifted = body + first + tail
        } else {
            shifted = String(atbashed)
        }

        let digitMapped = shifted.map { character -> Character in
            guard let scalar = character.unicodeScalars.first else {
                return character
            }
            if (48...57).contains(scalar.value) {
                let mapped = 48 + (10 - Int(scalar.value - 48))
                return Character(UnicodeScalar(mapped)!)
            }
            return character
        }

        return String(
            digitMapped.map { character in
                if character.isLowercase {
                    return Character(String(character).uppercased())
                }
                if character.isUppercase {
                    return Character(String(character).lowercased())
                }
                return character
            }
        )
    }

    private func parseDanmaku(from data: Data) throws -> [DanmakuComment] {
        guard
            let payload = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let rawComments = payload["comments"] as? [[String: Any]]
        else {
            throw DandanplayClientError.invalidResponse
        }

        var seen = Set<String>()
        var results: [DanmakuComment] = []
        for item in rawComments {
            guard
                let pValue = item["p"] as? String,
                let message = item["m"] as? String
            else {
                continue
            }
            let parts = pValue.split(
                separator: ",",
                omittingEmptySubsequences: false
            )
            let time = Double(parts[safe: 0] ?? "0") ?? 0
            let mode = Int(parts[safe: 1] ?? "1") ?? 1
            let colorValue = Int(parts[safe: 2] ?? "16777215") ?? 16_777_215

            let presentation: DanmakuPresentation
            switch mode {
            case 1:
                presentation = .scroll
            case 5:
                presentation = .top
            default:
                presentation = .bottom
            }

            let key = "\(Int(time * 1000))|\(mode)|\(colorValue)|\(message)"
            guard seen.insert(key).inserted else { continue }

            results.append(
                DanmakuComment(
                    time: time,
                    text: message,
                    presentation: presentation,
                    color: DanmakuColor.from(decimalColor: colorValue)
                )
            )
        }
        return results.sorted(by: { $0.time < $1.time })
    }

    private func requestData(
        apiPath: String,
        query: [URLQueryItem] = [],
        useProxy: Bool = false
    ) async throws -> Data {
        let secret = try await resolvedAppSecret()
        let timestamp = Int(Date().timeIntervalSince1970)

        let targetURL: URL
        if useProxy {
            var proxyComponents = URLComponents(
                url: danmakuProxyURL,
                resolvingAgainstBaseURL: false
            )!
            var pathComponents = URLComponents()
            pathComponents.path = apiPath
            pathComponents.queryItems = query.isEmpty ? nil : query
            proxyComponents.queryItems = [
                URLQueryItem(name: "path", value: pathComponents.string)
            ]
            targetURL = proxyComponents.url!
        } else {
            var components = URLComponents()
            components.scheme = apiBaseURL.scheme
            components.host = apiBaseURL.host
            components.path = apiPath
            components.queryItems = query.isEmpty ? nil : query
            targetURL = components.url!
        }

        var request = URLRequest(url: targetURL)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.appID, forHTTPHeaderField: "X-AppId")
        request.setValue(
            Self.signature(
                timestamp: timestamp,
                apiPath: apiPath,
                appSecret: secret
            ),
            forHTTPHeaderField: "X-Signature"
        )
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DandanplayClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message =
                httpResponse.value(forHTTPHeaderField: "X-Error-Message")
                ?? errorBody?.nilIfEmpty
                ?? "HTTP \(httpResponse.statusCode)"
            throw DandanplayClientError.requestFailed(message)
        }
        return data
    }

    private func resolvedAppSecret() async throws -> String {
        if let appSecret {
            return appSecret
        }

        for server in secretServers {
            do {
                var request = URLRequest(
                    url: server.appendingPathComponent("nipaplay.php")
                )
                request.timeoutInterval = 5
                request.setValue(
                    Self.userAgent,
                    forHTTPHeaderField: "User-Agent"
                )
                request.setValue(
                    "application/json",
                    forHTTPHeaderField: "Accept"
                )

                let (data, response) = try await URLSession.shared.data(
                    for: request
                )
                guard let httpResponse = response as? HTTPURLResponse,
                    httpResponse.statusCode == 200
                else {
                    continue
                }

                guard
                    let payload = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                    let encrypted = payload["encryptedAppSecret"] as? String
                else {
                    continue
                }

                let decoded = Self.decodeEncryptedAppSecret(encrypted)
                appSecret = decoded
                return decoded
            } catch {
                continue
            }
        }

        throw DandanplayClientError.missingSecret
    }

    private static func signature(
        timestamp: Int,
        apiPath: String,
        appSecret: String
    ) -> String {
        let raw = Data(
            (Self.appID + String(timestamp) + apiPath + appSecret).utf8
        )
        let digest = SHA256.hash(data: raw)
        return Data(digest).base64EncodedString()
    }
}

extension Array where Element == Substring {
    fileprivate subscript(safe index: Int) -> String? {
        guard indices.contains(index) else { return nil }
        return String(self[index])
    }
}
