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
    let contents: ExaContentsOptions?
    let livecrawl: String?
    let includeDomains: [String]?

    enum CodingKeys: String, CodingKey {
        case query, type, contents, livecrawl
        case numResults = "num_results"
        case includeDomains = "include_domains"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(query, forKey: .query)
        try container.encode(type, forKey: .type)
        try container.encode(numResults, forKey: .numResults)
        try container.encodeIfPresent(contents, forKey: .contents)
        try container.encodeIfPresent(livecrawl, forKey: .livecrawl)
        try container.encodeIfPresent(includeDomains, forKey: .includeDomains)
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
    ///   - maxCharacters: Max characters per result (default 2000). Set to nil to skip content fetching.
    ///   - searchType: Search type - fast, auto, or deep (default auto)
    ///   - livecrawl: Livecrawl mode - fallback, preferred, or always (default fallback)
    ///   - includeDomains: Limit search to specific domains (e.g., ["reddit.com"])
    func search(
        query: String,
        numResults: Int = 5,
        maxCharacters: Int? = 2000,
        searchType: SearchType = .auto,
        livecrawl: LivecrawlMode = .fallback,
        includeDomains: [String]? = nil
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
            contents: maxCharacters.map { ExaContentsOptions(text: ExaTextOptions(maxCharacters: $0)) },
            livecrawl: livecrawl.rawValue,
            includeDomains: includeDomains
        )

        request.httpBody = try JSONEncoder().encode(searchRequest)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            Logger.shared.error("Exa: Network error during search: \(error.localizedDescription)")
            throw ExaError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.shared.error("Exa: Invalid response type during search")
            throw ExaError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            Logger.shared.error("Exa: Authentication error (401)")
            throw ExaError.authenticationError
        case 429:
            Logger.shared.error("Exa: Rate limited (429)")
            throw ExaError.rateLimited
        default:
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.shared.error("Exa: API error (\(httpResponse.statusCode)): \(errorBody.prefix(200))")
            throw ExaError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        do {
            let searchResponse = try JSONDecoder().decode(ExaSearchResponse.self, from: data)
            return searchResponse.results
        } catch {
            Logger.shared.error("Exa: Failed to decode search response: \(error.localizedDescription)")
            throw ExaError.apiError(statusCode: 200, message: "Failed to parse response")
        }
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            Logger.shared.error("Exa: Network error during getContents: \(error.localizedDescription)")
            throw ExaError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.shared.error("Exa: Invalid response type during getContents")
            throw ExaError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            Logger.shared.error("Exa: Authentication error (401)")
            throw ExaError.authenticationError
        case 429:
            Logger.shared.error("Exa: Rate limited (429)")
            throw ExaError.rateLimited
        default:
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.shared.error("Exa: API error (\(httpResponse.statusCode)) during getContents: \(errorBody.prefix(200))")
            throw ExaError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        do {
            let contentsResponse = try JSONDecoder().decode(ExaContentsResponse.self, from: data)
            return contentsResponse.results
        } catch {
            Logger.shared.error("Exa: Failed to decode contents response: \(error.localizedDescription)")
            throw ExaError.apiError(statusCode: 200, message: "Failed to parse response")
        }
    }
}

// MARK: - Errors

enum ExaError: Error, LocalizedError {
    case invalidResponse
    case rateLimited
    case authenticationError
    case apiError(statusCode: Int, message: String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Exa API."
        case .rateLimited:
            return "Exa API rate limit exceeded. Wait a moment before retrying, or reduce the number of results requested."
        case .authenticationError:
            return "Exa API authentication failed. Check the API key configuration."
        case .apiError(let statusCode, let message):
            return "Exa API error (HTTP \(statusCode)): \(message)"
        case .networkError(let message):
            return "Network error connecting to Exa: \(message)"
        }
    }
}
