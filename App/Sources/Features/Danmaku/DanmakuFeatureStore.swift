import Combine
import Foundation

struct DanmakuAnimeMapping: Codable, Hashable {
    var sourceSeriesID: String
    var sourceSeasonID: String?
    var animeID: Int
    var animeTitle: String
    var updatedAt: Date
}

struct DanmakuEpisodeMapping: Codable, Hashable {
    var sourceEpisodeID: String
    var sourceSeriesID: String
    var sourceSeasonID: String?
    var sourceEpisodeNumber: Int?
    var animeID: Int
    var animeTitle: String
    var animeEpisodeID: Int
    var animeEpisodeNumber: Int?
    var animeEpisodeTitle: String
    var updatedAt: Date
}

struct DanmakuMatchMappingSnapshot: Codable, Hashable {
    var animeMappings: [String: DanmakuAnimeMapping] = [:]
    var episodeMappings: [String: DanmakuEpisodeMapping] = [:]
}

actor DanmakuMatchMappingStore {
    private static let defaultsKey = "starmine.danmaku.matchMappings.v1"

    private let userDefaults: UserDefaults?
    private let defaultsKey: String
    private var snapshot: DanmakuMatchMappingSnapshot

    init(
        userDefaults: UserDefaults = .standard,
        defaultsKey: String = DanmakuMatchMappingStore.defaultsKey
    ) {
        self.userDefaults = userDefaults
        self.defaultsKey = defaultsKey

        if let data = userDefaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(
                DanmakuMatchMappingSnapshot.self,
                from: data
            )
        {
            snapshot = decoded
        } else {
            snapshot = DanmakuMatchMappingSnapshot()
        }
    }

    init(snapshot: DanmakuMatchMappingSnapshot = DanmakuMatchMappingSnapshot())
    {
        userDefaults = nil
        defaultsKey = Self.defaultsKey
        self.snapshot = snapshot
    }

    func animeMapping(seriesID: String, seasonID: String?)
        -> DanmakuAnimeMapping?
    {
        snapshot.animeMappings[
            Self.animeMappingKey(seriesID: seriesID, seasonID: seasonID)
        ]
    }

    func episodeMapping(episodeID: String) -> DanmakuEpisodeMapping? {
        snapshot.episodeMappings[episodeID]
    }

    func episodeMappings(seriesID: String, seasonID: String?)
        -> [DanmakuEpisodeMapping]
    {
        snapshot.episodeMappings.values
            .filter {
                $0.sourceSeriesID == seriesID && $0.sourceSeasonID == seasonID
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.sourceEpisodeID < rhs.sourceEpisodeID
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func saveAnimeMapping(_ mapping: DanmakuAnimeMapping) {
        snapshot.animeMappings[
            Self.animeMappingKey(
                seriesID: mapping.sourceSeriesID,
                seasonID: mapping.sourceSeasonID
            )
        ] = mapping
        persistIfNeeded()
    }

    func saveEpisodeMapping(_ mapping: DanmakuEpisodeMapping) {
        snapshot.episodeMappings[mapping.sourceEpisodeID] = mapping
        persistIfNeeded()
    }

    func removeEpisodeMapping(episodeID: String) {
        snapshot.episodeMappings.removeValue(forKey: episodeID)
        persistIfNeeded()
    }

    func snapshotForTesting() -> DanmakuMatchMappingSnapshot {
        snapshot
    }

    private func persistIfNeeded() {
        guard let userDefaults else { return }
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            userDefaults.set(data, forKey: defaultsKey)
        }
    }

    private static func animeMappingKey(seriesID: String, seasonID: String?)
        -> String
    {
        "\(seriesID)#\(seasonID ?? "nil")"
    }
}

@MainActor
final class DanmakuFeatureStore: ObservableObject {
    @Published var searchQuery = ""
    @Published var searchResults: [AnimeSearchResult] = []
    @Published var selectedAnimeID: AnimeSearchResult.ID?
    @Published var episodes: [AnimeEpisode] = []
    @Published var selectedEpisodeID: AnimeEpisode.ID?
    @Published var isSearching = false
    @Published var isLoadingDanmaku = false

    let renderer = DanmakuRendererStore()

    private let client: any DandanplayClientProtocol
    private let mappingStore: DanmakuMatchMappingStore
    private(set) var inferredSeasonNumber: Int?
    private(set) var inferredSeasonEpisodeCount: Int?
    private(set) var inferredEpisodeNumber: Int?
    private(set) var remoteSeriesID: String?
    private(set) var remoteSeasonID: String?
    private(set) var remoteEpisodeID: String?

    init(
        client: any DandanplayClientProtocol = DandanplayClient(),
        mappingStore: DanmakuMatchMappingStore = DanmakuMatchMappingStore()
    ) {
        self.client = client
        self.mappingStore = mappingStore
    }

    var selectedAnime: AnimeSearchResult? {
        searchResults.first(where: { $0.id == selectedAnimeID })
    }

    var selectedEpisode: AnimeEpisode? {
        episodes.first(where: { $0.id == selectedEpisodeID })
    }

    func prepareSearch(
        query: String,
        inferredSeasonNumber: Int? = nil,
        inferredSeasonEpisodeCount: Int? = nil,
        inferredEpisodeNumber: Int?,
        remoteSeriesID: String? = nil,
        remoteSeasonID: String? = nil,
        remoteEpisodeID: String? = nil
    ) {
        searchQuery = query
        self.inferredSeasonNumber = inferredSeasonNumber
        self.inferredSeasonEpisodeCount = inferredSeasonEpisodeCount
        self.inferredEpisodeNumber = inferredEpisodeNumber
        self.remoteSeriesID = remoteSeriesID
        self.remoteSeasonID = remoteSeasonID
        self.remoteEpisodeID = remoteEpisodeID
        clearSelection(keepQuery: true)
        renderer.clear()
    }

    func clearAll() {
        inferredSeasonNumber = nil
        inferredSeasonEpisodeCount = nil
        inferredEpisodeNumber = nil
        remoteSeriesID = nil
        remoteSeasonID = nil
        remoteEpisodeID = nil
        clearSelection(keepQuery: false)
        renderer.clear()
    }

    func searchAndAutoloadDanmaku() async throws -> AnimeEpisode? {
        let keyword = searchQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !keyword.isEmpty else {
            clearSelection(keepQuery: true)
            return nil
        }

        if let mappedAnime = await preferredMappedAnime() {
            searchResults = [mappedAnime]
            selectedAnimeID = mappedAnime.id

            do {
                if let mappedEpisode = try await loadEpisodes(
                    for: mappedAnime,
                    autoloadDanmaku: true
                ) {
                    return mappedEpisode
                }
            } catch {
                selectedAnimeID = nil
                episodes = []
            }
        }

        isSearching = true
        defer { isSearching = false }

        let results = try await client.searchAnime(keyword: keyword)
        searchResults = results
        guard let bestMatch = bestSearchResult(in: results) else {
            episodes = []
            selectedAnimeID = nil
            return nil
        }

        selectedAnimeID = bestMatch.id
        return try await loadEpisodes(for: bestMatch, autoloadDanmaku: true)
    }

    func pickAnime(_ anime: AnimeSearchResult) async throws -> AnimeEpisode? {
        selectedAnimeID = anime.id
        return try await loadEpisodes(for: anime, autoloadDanmaku: true)
    }

    func pickEpisode(_ episode: AnimeEpisode) async throws {
        selectedEpisodeID = episode.id
        try await loadDanmaku(for: episode)
        if let anime = selectedAnime {
            await persistRemoteMappingIfNeeded(anime: anime, episode: episode)
        }
    }

    private func clearSelection(keepQuery: Bool) {
        if !keepQuery {
            searchQuery = ""
        }
        searchResults = []
        selectedAnimeID = nil
        episodes = []
        selectedEpisodeID = nil
    }

    private func loadEpisodes(
        for anime: AnimeSearchResult,
        autoloadDanmaku: Bool
    ) async throws -> AnimeEpisode? {
        let loadedEpisodes = try await client.loadEpisodes(for: anime.id)
        episodes = loadedEpisodes

        guard autoloadDanmaku else { return nil }

        let matchingEpisode = await resolvedEpisode(in: loadedEpisodes)
        if let matchingEpisode {
            selectedEpisodeID = matchingEpisode.id
            try await loadDanmaku(for: matchingEpisode)
            await persistRemoteMappingIfNeeded(
                anime: anime,
                episode: matchingEpisode
            )
        } else {
            renderer.clear()
        }
        return matchingEpisode
    }

    private func loadDanmaku(for episode: AnimeEpisode) async throws {
        isLoadingDanmaku = true
        defer { isLoadingDanmaku = false }

        let comments = try await client.loadDanmaku(
            episodeID: episode.id,
            chConvert: 0
        )
        renderer.load(comments)
    }

    private func bestSearchResult(in results: [AnimeSearchResult])
        -> AnimeSearchResult?
    {
        guard !results.isEmpty else { return nil }
        guard let inferredSeasonNumber else { return results.first }

        let ranked = results.enumerated().map { index, result in
            (
                index, result,
                score(for: result, preferredSeasonNumber: inferredSeasonNumber)
            )
        }
        return ranked.max { lhs, rhs in
            if lhs.2 == rhs.2 {
                return lhs.0 > rhs.0
            }
            return lhs.2 < rhs.2
        }?.1
    }

    private func score(
        for result: AnimeSearchResult,
        preferredSeasonNumber: Int
    ) -> Int {
        var score = 0
        if DandanplaySearchHeuristics.looksLikeSpecialResult(
            title: result.title,
            typeDescription: result.typeDescription
        ) {
            score -= 60
        }

        if let extractedSeasonNumber =
            DandanplaySearchHeuristics.extractSeasonNumber(from: result.title)
        {
            if extractedSeasonNumber == preferredSeasonNumber {
                score += 100
            } else {
                score -= abs(extractedSeasonNumber - preferredSeasonNumber) * 30
            }
        } else if preferredSeasonNumber == 1 {
            score += 45
        } else {
            score -= 20
        }

        if let inferredSeasonEpisodeCount,
            let resultEpisodeCount = result.episodeCount
        {
            let distance = abs(resultEpisodeCount - inferredSeasonEpisodeCount)
            switch distance {
            case 0:
                score += 20
            case 1...2:
                score += 8
            default:
                score -= min(distance, 6)
            }
        }

        return score
    }

    private func preferredMappedAnime() async -> AnimeSearchResult? {
        if let remoteEpisodeID,
            let episodeMapping = await mappingStore.episodeMapping(
                episodeID: remoteEpisodeID
            )
        {
            return AnimeSearchResult(
                id: episodeMapping.animeID,
                title: episodeMapping.animeTitle,
                typeDescription: "已缓存匹配",
                imageURL: nil,
                episodeCount: nil
            )
        }

        guard let remoteSeriesID else { return nil }
        guard
            let animeMapping = await mappingStore.animeMapping(
                seriesID: remoteSeriesID,
                seasonID: remoteSeasonID
            )
        else {
            return nil
        }

        return AnimeSearchResult(
            id: animeMapping.animeID,
            title: animeMapping.animeTitle,
            typeDescription: "已缓存匹配",
            imageURL: nil,
            episodeCount: nil
        )
    }

    private func resolvedEpisode(in loadedEpisodes: [AnimeEpisode]) async
        -> AnimeEpisode?
    {
        if let directlyMappedEpisode = await directlyMappedEpisode(
            in: loadedEpisodes
        ) {
            return directlyMappedEpisode
        }

        let mainEpisodes = loadedEpisodes.filter(\.hasNumericOrdinal)
        let candidateEpisodes =
            mainEpisodes.isEmpty ? loadedEpisodes : mainEpisodes

        if let predictedEpisode = await predictedMappedEpisode(
            in: candidateEpisodes
        ) {
            return predictedEpisode
        }

        guard let inferredEpisodeNumber, inferredEpisodeNumber > 0 else {
            return candidateEpisodes.first
        }
        if candidateEpisodes.indices.contains(inferredEpisodeNumber - 1) {
            return candidateEpisodes[inferredEpisodeNumber - 1]
        }
        return candidateEpisodes.first(where: {
            $0.number == inferredEpisodeNumber
        }) ?? candidateEpisodes.first
    }

    private func directlyMappedEpisode(in loadedEpisodes: [AnimeEpisode]) async
        -> AnimeEpisode?
    {
        guard let remoteEpisodeID else { return nil }
        guard
            let mapping = await mappingStore.episodeMapping(
                episodeID: remoteEpisodeID
            )
        else { return nil }

        if let exact = loadedEpisodes.first(where: {
            $0.id == mapping.animeEpisodeID
        }) {
            return exact
        }

        if let animeEpisodeNumber = mapping.animeEpisodeNumber,
            let numbered = loadedEpisodes.first(where: {
                $0.number == animeEpisodeNumber
            })
        {
            return numbered
        }

        await mappingStore.removeEpisodeMapping(episodeID: remoteEpisodeID)
        return nil
    }

    private func predictedMappedEpisode(in candidateEpisodes: [AnimeEpisode])
        async -> AnimeEpisode?
    {
        guard
            let remoteSeriesID,
            let inferredEpisodeNumber,
            inferredEpisodeNumber > 0
        else {
            return nil
        }

        let referenceMappings = await mappingStore.episodeMappings(
            seriesID: remoteSeriesID,
            seasonID: remoteSeasonID
        )
        .filter { $0.sourceEpisodeID != remoteEpisodeID }
        .sorted { lhs, rhs in
            let lhsDistance = abs(
                (lhs.sourceEpisodeNumber ?? inferredEpisodeNumber)
                    - inferredEpisodeNumber
            )
            let rhsDistance = abs(
                (rhs.sourceEpisodeNumber ?? inferredEpisodeNumber)
                    - inferredEpisodeNumber
            )
            if lhsDistance == rhsDistance {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhsDistance < rhsDistance
        }

        for mapping in referenceMappings {
            guard let sourceEpisodeNumber = mapping.sourceEpisodeNumber else {
                continue
            }

            let referenceIndex =
                candidateEpisodes.firstIndex(where: {
                    $0.id == mapping.animeEpisodeID
                })
                ?? mapping.animeEpisodeNumber.flatMap { number in
                    candidateEpisodes.firstIndex(where: { $0.number == number })
                }
            guard let referenceIndex else { continue }

            let predictedIndex =
                referenceIndex + (inferredEpisodeNumber - sourceEpisodeNumber)
            guard candidateEpisodes.indices.contains(predictedIndex) else {
                continue
            }
            return candidateEpisodes[predictedIndex]
        }

        return nil
    }

    private func persistRemoteMappingIfNeeded(
        anime: AnimeSearchResult,
        episode: AnimeEpisode
    ) async {
        guard let remoteSeriesID else { return }

        await mappingStore.saveAnimeMapping(
            DanmakuAnimeMapping(
                sourceSeriesID: remoteSeriesID,
                sourceSeasonID: remoteSeasonID,
                animeID: anime.id,
                animeTitle: anime.title,
                updatedAt: Date()
            )
        )

        guard let remoteEpisodeID else { return }

        await mappingStore.saveEpisodeMapping(
            DanmakuEpisodeMapping(
                sourceEpisodeID: remoteEpisodeID,
                sourceSeriesID: remoteSeriesID,
                sourceSeasonID: remoteSeasonID,
                sourceEpisodeNumber: inferredEpisodeNumber,
                animeID: anime.id,
                animeTitle: anime.title,
                animeEpisodeID: episode.id,
                animeEpisodeNumber: episode.number,
                animeEpisodeTitle: episode.title,
                updatedAt: Date()
            )
        )
    }
}

extension AnimeEpisode {
    fileprivate var hasNumericOrdinal: Bool {
        number != nil
    }
}
