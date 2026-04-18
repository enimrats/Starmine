import Foundation

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func foldedForSearch() -> String {
        folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    }

    func sanitizedFilenameComponent(fallback: String = "item") -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let punctuationReplacements = CharacterSet(
            charactersIn: "·•｡。､，,;；!！?？()（）[]【】{}<>《》“”‘’'\""
        )

        let scalarView = trimmed.unicodeScalars.map { scalar -> Character in
            if invalidCharacters.contains(scalar)
                || punctuationReplacements.contains(scalar)
            {
                return "-"
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return "-"
            }
            return Character(scalar)
        }

        let collapsed = String(scalarView)
            .replacingOccurrences(
                of: "-+",
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._ "))

        return collapsed.nilIfBlank ?? fallback
    }
}
