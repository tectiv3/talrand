import Foundation

// MARK: - Response Models

struct ScryfallImageUris: Codable {
    let small: String?
    let normal: String?
    let large: String?
    let png: String?
}

struct ScryfallCardFace: Codable {
    let name: String
    let imageUris: ScryfallImageUris?

    enum CodingKeys: String, CodingKey {
        case name
        case imageUris = "image_uris"
    }
}

struct ScryfallCard: Codable {
    let id: String
    let oracleId: String?
    let name: String
    let set: String
    let collectorNumber: String
    let oracleText: String?
    let manaCost: String?
    let typeLine: String?
    let colorIdentity: [String]?
    let power: String?
    let toughness: String?
    let rarity: String
    let layout: String
    let imageUris: ScryfallImageUris?
    let cardFaces: [ScryfallCardFace]?
    let printedName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case oracleId = "oracle_id"
        case name
        case set
        case collectorNumber = "collector_number"
        case printedName = "printed_name"
        case oracleText = "oracle_text"
        case manaCost = "mana_cost"
        case typeLine = "type_line"
        case colorIdentity = "color_identity"
        case power
        case toughness
        case rarity
        case layout
        case imageUris = "image_uris"
        case cardFaces = "card_faces"
    }
}

struct ScryfallRuling: Codable {
    let publishedAt: String
    let source: String
    let comment: String

    enum CodingKeys: String, CodingKey {
        case publishedAt = "published_at"
        case source
        case comment
    }
}

struct ScryfallSearchResult: Codable {
    let totalCards: Int
    let hasMore: Bool
    let nextPage: String?
    let data: [ScryfallCard]

    enum CodingKeys: String, CodingKey {
        case totalCards = "total_cards"
        case hasMore = "has_more"
        case nextPage = "next_page"
        case data
    }
}

struct ScryfallRulingsResponse: Codable {
    let data: [ScryfallRuling]
}

// MARK: - Card Face Selection

enum CardFace {
    case front
    case back
}

// MARK: - Error Types

enum ScryfallError: Error, LocalizedError {
    case networkError(Error)
    case decodingError(Error)
    case notFound
    case rateLimited
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .notFound:
            return "Card not found"
        case .rateLimited:
            return "Rate limited by Scryfall API"
        case .apiError(let message):
            return "API error: \(message)"
        }
    }
}

// MARK: - Scryfall Error Response

private struct ScryfallErrorResponse: Codable {
    let status: Int
    let details: String
}

// MARK: - Sets Response

private struct ScryfallSetsResponse: Codable {
    let data: [ScryfallSetEntry]
}

private struct ScryfallSetEntry: Codable {
    let code: String
}

// MARK: - API Client

actor ScryfallAPI {
    static let shared = ScryfallAPI()

    private let session: URLSession
    private let baseURL = "https://api.scryfall.com"
    private let decoder: JSONDecoder
    private var lastRequestTime: ContinuousClock.Instant?

    // Scryfall asks for 50-100ms between requests
    private let minimumRequestInterval: Duration = .milliseconds(50)

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "Talrand/1.0"
        ]
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    // MARK: - Public API

    func fetchCard(scryfallId: String) async throws -> ScryfallCard {
        let url = "\(baseURL)/cards/\(scryfallId)"
        return try await request(url: url)
    }

    func fetchRulings(scryfallId: String) async throws -> [ScryfallRuling] {
        let url = "\(baseURL)/cards/\(scryfallId)/rulings"
        let response: ScryfallRulingsResponse = try await request(url: url)
        return response.data
    }

    func fetchAllPrintings(oracleId: String) async throws -> [ScryfallCard] {
        let encodedId = oracleId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? oracleId
        let firstPageURL = "\(baseURL)/cards/search?q=oracleid%3A\(encodedId)&unique=prints"

        var allCards: [ScryfallCard] = []
        var nextURL: String? = firstPageURL

        while let url = nextURL {
            let result: ScryfallSearchResult = try await request(url: url)
            allCards.append(contentsOf: result.data)
            nextURL = result.hasMore ? result.nextPage : nil
        }

        return allCards
    }

    /// The card's printed name in a given language (default Japanese), taken from
    /// any printing in that language. Used to identify physical foreign cards by
    /// title. Returns nil when no printing exists in that language.
    func fetchLocalizedName(oracleId: String, lang: String = "ja") async -> String? {
        guard !oracleId.isEmpty,
              let encodedId = oracleId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let url = "\(baseURL)/cards/search?q=oracleid%3A\(encodedId)+lang%3A\(lang)&unique=prints"
        let result: ScryfallSearchResult? = try? await request(url: url)
        return result?.data.compactMap { $0.printedName }.first { !$0.isEmpty }
    }

    func searchCards(query: String) async throws -> [ScryfallCard] {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw ScryfallError.apiError("Invalid query string")
        }
        // unique=prints so every printing (art) shows, letting the caller pick
        // the one matching their physical card; newest first.
        let url = "\(baseURL)/cards/search?q=\(encodedQuery)&unique=prints&order=released&dir=desc"
        let result: ScryfallSearchResult = try await request(url: url)
        return result.data
    }

    func fetchCardBySetAndNumber(setCode: String, collectorNumber: String) async throws -> ScryfallCard {
        let encodedNumber = collectorNumber.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? collectorNumber
        let url = "\(baseURL)/cards/\(setCode.lowercased())/\(encodedNumber)"
        return try await request(url: url)
    }

    func fetchSetCodes() async -> [String] {
        let cacheKey = "cachedMTGSetCodes"
        let cacheDateKey = "cachedMTGSetCodesDate"
        let defaults = UserDefaults.standard
        let cachedCodes = defaults.stringArray(forKey: cacheKey)
        let cachedDate = defaults.object(forKey: cacheDateKey) as? Date

        if let codes = cachedCodes, let date = cachedDate,
           Date().timeIntervalSince(date) < 7 * 24 * 60 * 60 {
            return codes
        }

        do {
            let url = "\(baseURL)/sets"
            let response: ScryfallSetsResponse = try await request(url: url)
            let codes = response.data.map { $0.code.uppercased() }
            defaults.set(codes, forKey: cacheKey)
            defaults.set(Date(), forKey: cacheDateKey)
            return codes
        } catch {
            return cachedCodes ?? []
        }
    }

    // MARK: - Image URL Helper

    func imageUrl(for card: ScryfallCard, face: CardFace = .front) -> String? {
        let dualFaceLayouts: Set<String> = ["transform", "modal_dfc"]

        if dualFaceLayouts.contains(card.layout) {
            switch face {
            case .front:
                return card.cardFaces?.first?.imageUris?.normal
            case .back:
                return card.cardFaces?.dropFirst().first?.imageUris?.normal
            }
        }

        return card.imageUris?.normal
    }

    // MARK: - Internal

    private func enforceRateLimit() async throws {
        if let last = lastRequestTime {
            let elapsed = ContinuousClock.now - last
            if elapsed < minimumRequestInterval {
                try await Task.sleep(for: minimumRequestInterval - elapsed)
            }
        }
        lastRequestTime = .now
    }

    private func request<T: Decodable>(url urlString: String) async throws -> T {
        guard let url = URL(string: urlString) else {
            throw ScryfallError.apiError("Invalid URL: \(urlString)")
        }

        try await enforceRateLimit()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw ScryfallError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScryfallError.networkError(
                URLError(.badServerResponse)
            )
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 404:
            throw ScryfallError.notFound
        case 429:
            throw ScryfallError.rateLimited
        default:
            if let errorResponse = try? decoder.decode(ScryfallErrorResponse.self, from: data) {
                throw ScryfallError.apiError(errorResponse.details)
            }
            throw ScryfallError.apiError("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ScryfallError.decodingError(error)
        }
    }
}
