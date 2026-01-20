import Foundation

/// Web search tool powered by Exa AI.
/// Allows the agent to search the web for current information with configurable parameters.
final class WebSearchTool: Tool {
    let name = "web_search"

    let description = """
        Search the web using Exa's neural search. Returns raw page content for you to synthesize.

        When to use:
        - Information likely outdated or changed since August 2025
        - Facts you're uncertain about (dates, statistics, current status)
        - Current events, news, prices, recent developments
        - Technical docs, APIs, or specs that update frequently

        When NOT to use:
        - You confidently know the answer
        - Reasoning, analysis, math, or creative tasks
        - Well-established facts within your training data
        """

    let parameters: [ToolParameter] = [
        ToolParameter(
            name: "query",
            type: .string,
            description: "The search query. Be specific and targeted for better results."
        ),
        ToolParameter(
            name: "num_results",
            type: .integer,
            description: "Number of results to return (1-50). Default: 5. Use 3-5 for simple facts, 10-20 for research.",
            required: false
        ),
        ToolParameter(
            name: "max_characters",
            type: .integer,
            description: "Max characters of content per result. Default: 2000. Use 1000-2000 for quick answers, 5000+ for detailed content.",
            required: false
        ),
        ToolParameter(
            name: "search_type",
            type: .string,
            description: "Search type. Default: 'auto'. Options: 'fast' (<500ms, quick lookups), 'auto' (balanced), 'deep' (comprehensive, several seconds).",
            required: false,
            enumValues: ["fast", "auto", "deep"]
        ),
        ToolParameter(
            name: "livecrawl",
            type: .string,
            description: "Content freshness. Default: 'fallback' (cached, faster). Use 'preferred' for current events, 'always' for real-time data.",
            required: false,
            enumValues: ["fallback", "preferred", "always"]
        )
    ]

    private let exaClient = ExaClient()

    func execute(arguments: String) async throws -> String {
        // Parse arguments
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalidArguments("Failed to parse arguments as JSON")
        }

        guard let query = args["query"] as? String, !query.isEmpty else {
            throw ToolError.invalidArguments("Missing or empty 'query' parameter. Provide a search query string.")
        }

        // Parse and validate num_results
        var numResults = 5
        if let n = args["num_results"] as? Int {
            if n < 1 || n > 50 {
                throw ToolError.invalidArguments("num_results must be between 1 and 50 (got \(n))")
            }
            numResults = n
        }

        // Parse and validate max_characters
        var maxCharacters = 2000
        if let m = args["max_characters"] as? Int {
            if m < 100 || m > 20000 {
                throw ToolError.invalidArguments("max_characters must be between 100 and 20000 (got \(m))")
            }
            maxCharacters = m
        }

        // Parse search_type with validation
        let searchTypeStr = args["search_type"] as? String ?? "auto"
        guard let searchType = SearchType(rawValue: searchTypeStr) else {
            throw ToolError.invalidArguments("Invalid search_type '\(searchTypeStr)'. Must be one of: fast, auto, deep")
        }

        // Parse livecrawl with validation
        let livecrawlStr = args["livecrawl"] as? String ?? "fallback"
        guard let livecrawl = LivecrawlMode(rawValue: livecrawlStr) else {
            throw ToolError.invalidArguments("Invalid livecrawl '\(livecrawlStr)'. Must be one of: fallback, preferred, always")
        }

        // Execute search
        let results = try await exaClient.search(
            query: query,
            numResults: numResults,
            maxCharacters: maxCharacters,
            searchType: searchType,
            livecrawl: livecrawl
        )

        // Format results for the AI
        if results.isEmpty {
            return "No results found for query: \(query)"
        }

        var output = "Search results for: \(query)\n"
        output += "[type: \(searchTypeStr), results: \(results.count), max_chars: \(maxCharacters)]\n"
        output += String(repeating: "=", count: 60) + "\n\n"

        for (index, result) in results.enumerated() {
            output += "[\(index + 1)] \(result.title ?? "Untitled")\n"
            output += "URL: \(result.url)\n"

            if let author = result.author, !author.isEmpty {
                output += "Author: \(author)\n"
            }
            if let publishedDate = result.publishedDate {
                output += "Published: \(publishedDate)\n"
            }

            if let text = result.text, !text.isEmpty {
                output += "\n\(text)\n"
            }

            output += "\n" + String(repeating: "-", count: 60) + "\n\n"
        }

        return output
    }
}
