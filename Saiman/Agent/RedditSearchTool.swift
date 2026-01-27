import Foundation

/// Reddit search tool powered by Exa AI.
/// Finds relevant Reddit threads using Exa's neural search with domain filtering.
final class RedditSearchTool: Tool {
    let name = "reddit_search"

    let description = """
        Search Reddit for threads and discussions. Returns titles, URLs, subreddits, and dates. \
        Use reddit_read to fetch full thread content and comments.

        When to use:
        - Recommendations (restaurants, APIs, libraries, tools)
        - Opinions and experiences ("is X worth it", "X vs Y")
        - Real-world troubleshooting ("X not working")
        - Local knowledge (city subreddits for restaurants, neighborhoods, etc.)
        """

    let parameters: [ToolParameter] = [
        ToolParameter(
            name: "query",
            type: .string,
            description: "Search query. Include subreddit names to filter (e.g., 'buyitforlife best backpack')."
        ),
        ToolParameter(
            name: "num_results",
            type: .integer,
            description: "Number of threads to return (1-30). Default: 10.",
            required: false
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
            throw ToolError.invalidArguments("Missing or empty 'query' parameter.")
        }

        // Parse and validate num_results
        var numResults = 10
        if let n = args["num_results"] as? Int {
            if n < 1 || n > 30 {
                throw ToolError.invalidArguments("num_results must be between 1 and 30 (got \(n))")
            }
            numResults = n
        }

        // Search Reddit using Exa with domain filtering
        // Don't request content - Exa can't crawl Reddit
        let results = try await exaClient.search(
            query: query,
            numResults: numResults,
            maxCharacters: nil,  // Skip content fetching
            searchType: .auto,
            livecrawl: .fallback,
            includeDomains: ["reddit.com"]
        )

        // Format results
        if results.isEmpty {
            return "No Reddit threads found for: \(query)"
        }

        var output = "Reddit search results for: \(query)\n"
        output += String(repeating: "=", count: 60) + "\n\n"

        for (index, result) in results.enumerated() {
            output += "[\(index + 1)] \(result.title ?? "Untitled")\n"

            // Extract subreddit from URL
            let subreddit = extractSubreddit(from: result.url) ?? "reddit"
            output += "    \(subreddit)"

            // Format date
            if let dateStr = result.publishedDate {
                let formatted = formatDate(dateStr)
                output += " | \(formatted)"
            }

            output += "\n    \(result.url)\n\n"
        }

        return output
    }

    /// Extract subreddit name from Reddit URL
    private func extractSubreddit(from url: String) -> String? {
        // Match /r/subredditname/ in the URL
        let pattern = #"/r/([^/]+)/"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let range = Range(match.range(at: 1), in: url) else {
            return nil
        }
        return "r/" + String(url[range])
    }

    /// Format ISO date string to readable format (e.g., "Oct 15, 2024")
    private func formatDate(_ isoDate: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]

        // Try parsing with different formats
        var date: Date?

        // Try full ISO8601
        date = isoFormatter.date(from: isoDate)

        // Try with time
        if date == nil {
            isoFormatter.formatOptions = [.withInternetDateTime]
            date = isoFormatter.date(from: isoDate)
        }

        // Try simple date format
        if date == nil {
            let simpleFormatter = DateFormatter()
            simpleFormatter.dateFormat = "yyyy-MM-dd"
            date = simpleFormatter.date(from: String(isoDate.prefix(10)))
        }

        guard let parsedDate = date else {
            return isoDate  // Return original if parsing fails
        }

        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "MMM d, yyyy"
        return outputFormatter.string(from: parsedDate)
    }
}
