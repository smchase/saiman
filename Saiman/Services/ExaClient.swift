import Foundation

// MARK: - Search Depth Configuration

enum SearchDepth: String {
    case quick  // Fast factual lookups
    case deep   // Comprehensive research

    var numResults: Int {
        switch self {
        case .quick: return 5
        case .deep: return 10
        }
    }

    var maxCharacters: Int {
        switch self {
        case .quick: return 3000
        case .deep: return 10000
        }
    }

    var searchType: String {
        switch self {
        case .quick: return "auto"
        case .deep: return "deep"
        }
    }

    var livecrawl: String? {
        switch self {
        case .quick: return nil  // Use default/cached
        case .deep: return "preferred"  // Try fresh content
        }
    }
}

// MARK: - Exa API Types

struct ExaSearchRequest: Encodable {
    let query: String
    let type: String
    let numResults: Int
    let contents: ExaContentsOptions
    let livecrawl: String?

    enum CodingKeys: String, CodingKey {
        case query, type, contents, livecrawl
        case numResults = "num_results"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(query, forKey: .query)
        try container.encode(type, forKey: .type)
        try container.encode(numResults, forKey: .numResults)
        try container.encode(contents, forKey: .contents)
        try container.encodeIfPresent(livecrawl, forKey: .livecrawl)
    }
}

struct ExaContentsOptions: Encodable {
    let text: ExaTextOptions
}

struct ExaTextOptions: Encodable {
    let maxCharacters: Int

    enum CodingKeys: String, CodingKey {
        case maxCharacters = "max_characters"
    }
}

struct ExaSearchResponse: Decodable {
    let results: [ExaResult]
}

struct ExaResult: Decodable {
    let title: String?
    let url: String
    let text: String?
    let publishedDate: String?
    let author: String?

    enum CodingKeys: String, CodingKey {
        case title, url, text, author
        case publishedDate = "published_date"
    }
}

// MARK: - Exa Client

final class ExaClient {
    private let config = Config.shared
    private let baseURL = "https://api.exa.ai"

    func search(query: String, depth: SearchDepth = .quick) async throws -> [ExaResult] {
        let url = URL(string: "\(baseURL)/search")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.exaApiKey)", forHTTPHeaderField: "Authorization")

        let searchRequest = ExaSearchRequest(
            query: query,
            type: depth.searchType,
            numResults: depth.numResults,
            contents: ExaContentsOptions(
                text: ExaTextOptions(maxCharacters: depth.maxCharacters)
            ),
            livecrawl: depth.livecrawl
        )

        request.httpBody = try JSONEncoder().encode(searchRequest)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExaError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ExaError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let searchResponse = try JSONDecoder().decode(ExaSearchResponse.self, from: data)
        return searchResponse.results
    }
}

// MARK: - Errors

enum ExaError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Exa API"
        case .apiError(let statusCode, let message):
            return "Exa API error (\(statusCode)): \(message)"
        }
    }
}
