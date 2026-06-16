import Foundation

struct CollectorNumberCandidate: Hashable {
    let setCode: String?
    let collectorNumber: String
}

struct CollectorNumberParser {

    static func parse(ocrText: String) -> [CollectorNumberCandidate] {
        var seen = Set<CollectorNumberCandidate>()
        var results: [CollectorNumberCandidate] = []

        func add(_ candidate: CollectorNumberCandidate) {
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

        return results
    }
}
