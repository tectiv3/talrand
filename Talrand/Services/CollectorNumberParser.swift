import Foundation

struct CollectorNumberCandidate: Hashable {
    let setCode: String?
    let collectorNumber: String
}

/// Reads the card's type line (English or Japanese) to a Scryfall type keyword,
/// used only as a tiebreaker when a collector number maps to several deck cards.
struct CardTypeParser {
    private static let japanese: [(jp: String, en: String)] = [
        ("プレインズウォーカー", "Planeswalker"),
        ("アーティファクト", "Artifact"),
        ("エンチャント", "Enchantment"),
        ("インスタント", "Instant"),
        ("クリーチャー", "Creature"),
        ("ソーサリー", "Sorcery"),
        ("バトル", "Battle"),
        ("土地", "Land"),
    ]
    private static let english = [
        "Planeswalker", "Artifact", "Enchantment", "Instant",
        "Creature", "Sorcery", "Battle", "Land",
    ]

    static func parse(_ text: String) -> String? {
        for type in english where text.localizedCaseInsensitiveContains(type) {
            return type
        }
        for entry in japanese where text.contains(entry.jp) {
            return entry.en
        }
        return nil
    }
}

/// Matches an OCR'd card title against the deck's known names (English + the
/// Japanese printed name). Precision over recall: it only returns a hit when the
/// full card name appears within the OCR text and exactly one deck card matches,
/// so furigana/noise in the title bar can't produce a wrong identification.
struct CardNameMatcher {
    /// Lowercased, stripped of whitespace and separators; CJK and alphanumerics
    /// survive so "渦まく知識" / "Brainstorm" compare cleanly across OCR noise.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0.value > 0x2E7F // keep CJK
        })
    }

    static func match(ocrText: String, candidates: [(name: String, id: String)]) -> String? {
        let q = normalize(ocrText)
        guard q.count >= 3 else { return nil }
        var hits = Set<String>()
        for candidate in candidates {
            let n = normalize(candidate.name)
            guard n.count >= 3 else { continue }
            if q.contains(n) { hits.insert(candidate.id) }
        }
        return hits.count == 1 ? hits.first : nil
    }
}

struct CollectorNumberParser {

    static func parse(ocrText: String, knownSetCodes: Set<String> = []) -> [CollectorNumberCandidate] {
        var seen = Set<CollectorNumberCandidate>()
        var results: [CollectorNumberCandidate] = []

        func add(_ raw: CollectorNumberCandidate) {
            // Modern/JP cards print zero-padded numbers ("048", "0160") but
            // Scryfall stores them unpadded ("48", "160"); normalize so lookups
            // hit. Compound/lettered numbers (e.g. "MRD-159") are left intact.
            var candidate = raw
            if raw.collectorNumber.allSatisfy(\.isNumber), let n = Int(raw.collectorNumber) {
                candidate = CollectorNumberCandidate(setCode: raw.setCode, collectorNumber: String(n))
            }
            if let set = candidate.setCode, !knownSetCodes.isEmpty, !knownSetCodes.contains(set.uppercased()) {
                return
            }
            guard seen.insert(candidate).inserted else { return }
            results.append(candidate)
        }

        // Pattern 1: Set code + number (post-M15)
        // e.g. "CMM 124", "STX · 37", "FDN-586"
        if let regex = try? NSRegularExpression(pattern: #"([A-Z]{2,5})\s*[·•.\-]?\s*(\d{1,4})"#) {
            let matches = regex.matches(in: ocrText, range: NSRange(ocrText.startIndex..., in: ocrText))
            for match in matches {
                guard let setRange = Range(match.range(at: 1), in: ocrText),
                      let numRange = Range(match.range(at: 2), in: ocrText) else { continue }
                let setCode = String(ocrText[setRange]).lowercased()
                let number = String(ocrText[numRange])
                add(CollectorNumberCandidate(setCode: setCode, collectorNumber: number))
            }
        }

        // Pattern 2: Number/total (any era)
        // e.g. "61/350", "124/674". The denominator is the set total, always
        // large — guarding on it rejects creature power/toughness like "4/4".
        if let regex = try? NSRegularExpression(pattern: #"(\d{1,4})\s*/\s*(\d{1,4})"#) {
            let matches = regex.matches(in: ocrText, range: NSRange(ocrText.startIndex..., in: ocrText))
            for match in matches {
                guard let numRange = Range(match.range(at: 1), in: ocrText),
                      let denRange = Range(match.range(at: 2), in: ocrText),
                      let total = Int(ocrText[denRange]), total >= 20 else { continue }
                let number = String(ocrText[numRange])
                add(CollectorNumberCandidate(setCode: nil, collectorNumber: number))
            }
        }

        // Pattern 3: Compound form (The List, reprints)
        // e.g. "MRD-159", "M11-64"
        // The collector number in Scryfall IS the compound form
        if let regex = try? NSRegularExpression(pattern: #"([A-Z]{2,4})-(\d{1,4})"#) {
            let matches = regex.matches(in: ocrText, range: NSRange(ocrText.startIndex..., in: ocrText))
            for match in matches {
                guard let setRange = Range(match.range(at: 1), in: ocrText),
                      let numRange = Range(match.range(at: 2), in: ocrText) else { continue }
                let setCode = String(ocrText[setRange])
                let number = String(ocrText[numRange])
                let compound = "\(setCode)-\(number)"
                add(CollectorNumberCandidate(setCode: nil, collectorNumber: compound))
            }
        }

        // Pattern 4: Split-line layout (modern cards)
        // Rarity + number on one line, set code on another: "R 0057 ... SOS • EN"
        let rarityNumberPattern = try? NSRegularExpression(pattern: #"[RCUMSPBT]\s+0*(\d{1,4})\b"#)
        let setCodePattern = try? NSRegularExpression(pattern: #"([A-Z]{2,5})\s*[·•]\s*[A-Z]{2}\b"#)

        if let rnRegex = rarityNumberPattern, let scRegex = setCodePattern {
            let rnMatches = rnRegex.matches(in: ocrText, range: NSRange(ocrText.startIndex..., in: ocrText))
            let scMatches = scRegex.matches(in: ocrText, range: NSRange(ocrText.startIndex..., in: ocrText))

            for scMatch in scMatches {
                guard let setRange = Range(scMatch.range(at: 1), in: ocrText) else { continue }
                let setCode = String(ocrText[setRange]).lowercased()

                for rnMatch in rnMatches {
                    guard let numRange = Range(rnMatch.range(at: 1), in: ocrText) else { continue }
                    let number = String(ocrText[numRange])
                    add(CollectorNumberCandidate(setCode: setCode, collectorNumber: number))
                }
            }
        }

        return results
    }
}
