import Foundation

struct CollectorNumberCandidate: Hashable {
    let setCode: String?
    let collectorNumber: String
}

struct CollectorNumberParser {

    static func parse(ocrText: String, knownSetCodes: Set<String> = []) -> [CollectorNumberCandidate] {
        var seen = Set<CollectorNumberCandidate>()
        var results: [CollectorNumberCandidate] = []

        func add(_ candidate: CollectorNumberCandidate) {
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
        // e.g. "61/350", "124/674"
        if let regex = try? NSRegularExpression(pattern: #"(\d{1,4})\s*/\s*\d{1,4}"#) {
            let matches = regex.matches(in: ocrText, range: NSRange(ocrText.startIndex..., in: ocrText))
            for match in matches {
                guard let numRange = Range(match.range(at: 1), in: ocrText) else { continue }
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
