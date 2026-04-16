import Foundation

enum DandanplaySearchHeuristics {
    static func cleanSearchKeyword(from raw: String) -> String {
        var cleaned = raw
        let patterns = [
            #"\[[^\]]*\]"#,
            #"【[^】]*】"#,
            #"\([^)]*\)"#,
            #"（[^）]*）"#,
            #"「[^」]*」"#,
            #"『[^』]*』"#,
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        cleaned =
            cleaned
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let range = cleaned.range(
            of: #"(?:第?\s*\d{1,3}\s*(?:话|集|話)|ep?\s*\d{1,3})"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            cleaned.removeSubrange(range)
        }

        return
            cleaned
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractEpisodeNumber(from raw: String) -> Int? {
        let pattern =
            #"(?:第\s*(\d{1,3})\s*[话話集]|ep?\s*(\d{1,3})|(?:^|[^0-9])(\d{1,3})(?=$|[^0-9]))"#
        let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        )
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches =
            expression?.matches(in: raw, options: [], range: range) ?? []

        var candidate: Int?
        for match in matches {
            for index in 1..<match.numberOfRanges {
                let groupRange = match.range(at: index)
                guard
                    groupRange.location != NSNotFound,
                    let swiftRange = Range(groupRange, in: raw),
                    let value = Int(raw[swiftRange])
                else {
                    continue
                }

                if [4, 264, 265, 480, 720, 1080, 2160].contains(value) {
                    continue
                }
                if value <= 0 || value > 300 {
                    continue
                }
                candidate = value
            }
        }
        return candidate
    }

    static func extractSeasonNumber(from raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let explicit = firstSeasonMatch(
            in: trimmed,
            patterns: [
                #"第\s*([零〇一二两三四五六七八九十\d]{1,4})\s*季"#,
                #"第\s*([零〇一二两三四五六七八九十\d]{1,4})\s*期"#,
                #"season\s*([ivx\d]{1,8})"#,
                #"\bs\s*([0-9]{1,2})\b"#,
            ]
        ) {
            return explicit
        }

        let lowercased = trimmed.lowercased()
        if lowercased.contains("second season") { return 2 }
        if lowercased.contains("third season") { return 3 }
        if lowercased.contains("fourth season") { return 4 }
        if lowercased.contains("fifth season") { return 5 }
        if lowercased.contains("sixth season") { return 6 }

        let normalized = trimmed.replacingOccurrences(
            of: #"[·・:：\-_.~／/]+"#,
            with: " ",
            options: .regularExpression
        )
        let tokens =
            normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        if let token = tokens.first, ["续", "續", "贰", "貳"].contains(token) {
            return 2
        }

        if let token = tokens.last {
            if let sequelSeason = sequelSeasonNumber(for: token) {
                return sequelSeason
            }
            if let romanSeason = romanSeasonNumber(for: token) {
                return romanSeason
            }
        }

        return nil
    }

    static func looksLikeSpecialResult(title: String, typeDescription: String)
        -> Bool
    {
        let normalized = "\(title) \(typeDescription)".lowercased()
        let markers = [
            "ova", "oad", "sp", "special", "specials", "剧场版", "劇場版",
            "movie", "movies", "电影", "電影", "特典", "总集篇", "總集篇", "cm", "opening",
            "ending",
        ]
        return markers.contains(where: { normalized.contains($0) })
    }

    private static func firstSeasonMatch(in raw: String, patterns: [String])
        -> Int?
    {
        for pattern in patterns {
            guard
                let expression = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                )
            else {
                continue
            }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard
                let match = expression.firstMatch(
                    in: raw,
                    options: [],
                    range: range
                ),
                match.numberOfRanges > 1,
                let swiftRange = Range(match.range(at: 1), in: raw)
            else {
                continue
            }
            let token = String(raw[swiftRange])
            if let arabic = Int(token) {
                return arabic
            }
            if let chinese = chineseSeasonNumber(from: token) {
                return chinese
            }
            if let roman = romanSeasonNumber(for: token) {
                return roman
            }
        }
        return nil
    }

    private static func chineseSeasonNumber(from raw: String) -> Int? {
        let normalized =
            raw
            .replacingOccurrences(of: "零", with: "0")
            .replacingOccurrences(of: "〇", with: "0")
            .replacingOccurrences(of: "两", with: "二")

        let directMap: [String: Int] = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
        ]
        if let direct = directMap[normalized] {
            return direct
        }
        if normalized.hasPrefix("十"),
            let ones = directMap[String(normalized.dropFirst())]
        {
            return 10 + ones
        }
        if normalized.hasSuffix("十"),
            let tens = directMap[String(normalized.dropLast())]
        {
            return tens * 10
        }
        if normalized.count == 3, normalized.contains("十") {
            let pieces = normalized.split(
                separator: "十",
                omittingEmptySubsequences: false
            ).map(String.init)
            if let tens = directMap[pieces.first ?? ""],
                let ones = directMap[pieces.last ?? ""]
            {
                return tens * 10 + ones
            }
        }
        return nil
    }

    private static func sequelSeasonNumber(for token: String) -> Int? {
        let map: [String: Int] = [
            "续": 2, "續": 2, "贰": 2, "貳": 2,
            "参": 3, "叁": 3,
            "肆": 4,
            "伍": 5,
            "陆": 6, "陸": 6,
            "柒": 7,
            "捌": 8,
            "玖": 9,
            "拾": 10,
        ]
        return map[token]
    }

    private static func romanSeasonNumber(for token: String) -> Int? {
        switch token.uppercased() {
        case "II": return 2
        case "III": return 3
        case "IV": return 4
        case "V": return 5
        case "VI": return 6
        case "VII": return 7
        case "VIII": return 8
        case "IX": return 9
        case "X": return 10
        default: return nil
        }
    }
}
