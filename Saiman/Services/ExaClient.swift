import Foundation

// MARK: - Search Configuration

enum SearchType: String {
    case fast   // Quick lookups, <500ms
    case auto   // Balanced quality/speed (default)
    case deep   // Comprehensive research, several seconds
}

enum LivecrawlMode: String {
    case fallback   // Use cached content first (faster, default)
    case preferred  // Try fresh content (for current events)
    case always     // Force fresh crawl (real-time data)
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

struct ExaContentsRequest: Encodable {
    let urls: [String]
    let text: ExaTextOptions
    let livecrawl: String?
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

struct ExaContentsResponse: Decodable {
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

    /// Search the web with configurable parameters
    /// - Parameters:
    ///   - query: The search query
    ///   - numResults: Number of results (1-50, default 5)
    ///   - maxCharacters: Max characters per result (default 2000)
    ///   - searchType: Search type - fast, auto, or deep (default auto)
    ///   - livecrawl: Livecrawl mode - fallback, preferred, or always (default fallback)
    func search(
        query: String,
        numResults: Int = 5,
        maxCharacters: Int = 2000,
        searchType: SearchType = .auto,
        livecrawl: LivecrawlMode = .fallback
    ) async throws -> [ExaResult] {
        let url = URL(string: "\(baseURL)/search")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.exaApiKey)", forHTTPHeaderField: "Authorization")

        let searchRequest = ExaSearchRequest(
            query: query,
            type: searchType.rawValue,
            numResults: numResults,
            contents: ExaContentsOptions(
                text: ExaTextOptions(maxCharacters: maxCharacters)
            ),
            livecrawl: livecrawl.rawValue
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

    /// Fetch contents from specific URLs
    /// - Parameters:
    ///   - urls: Array of URLs to fetch
    ///   - maxCharacters: Max characters per page (default 5000)
    ///   - livecrawl: Livecrawl mode (default fallback)
    func getContents(
        urls: [String],
        maxCharacters: Int = 5000,
        livecrawl: LivecrawlMode = .fallback
    ) async throws -> [ExaResult] {
        let url = URL(string: "\(baseURL)/contents")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.exaApiKey)", forHTTPHeaderField: "Authorization")

        let contentsRequest = ExaContentsRequest(
            urls: urls,
            text: ExaTextOptions(maxCharacters: maxCharacters),
            livecrawl: livecrawl.rawValue
        )

        request.httpBody = try JSONEncoder().encode(contentsRequest)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExaError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ExaError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let contentsResponse = try JSONDecoder().decode(ExaContentsResponse.self, from: data)
        return contentsResponse.results
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
