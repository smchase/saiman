import Foundation

/// Tool for fetching content from specific URLs.
/// Use when user shares a URL or when the agent needs full content from a known page.
final class GetPageContentsTool: Tool {
    let name = "get_page_contents"

    let description = """
        Fetch full content from specific URLs. Use when you have a URL and need to read it - \
        e.g., a link the user shared, or a page from search results you want to explore deeper. \
        Returns raw page content.
        """

    let parameters: [ToolParameter] = [
        ToolParameter(
            name: "urls",
            type: .array,
            description: "URL or array of URLs to fetch content from."
        ),
        ToolParameter(
            name: "max_characters",
            type: .integer,
            description: "Max characters of content per page. Default: 5000. Use higher values for long articles.",
            required: false
        ),
        ToolParameter(
            name: "livecrawl",
            type: .string,
            description: "Content freshness. Default: 'fallback' (cached, faster). Use 'preferred' for pages that update frequently.",
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

        // Parse URLs - can be a single string or array of strings
        let urls: [String]
        if let urlArray = args["urls"] as? [String] {
            urls = urlArray
        } else if let singleUrl = args["urls"] as? String {
            urls = [singleUrl]
        } else {
            throw ToolError.invalidArguments("Missing required 'urls' parameter. Provide a URL string or array of URLs.")
        }

        guard !urls.isEmpty else {
            throw ToolError.invalidArguments("URLs array cannot be empty. Provide at least one URL.")
        }

        // Validate URLs have proper format
        for url in urls {
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
                throw ToolError.invalidArguments("Invalid URL '\(url)'. URLs must start with http:// or https://")
            }
        }

        // Limit number of URLs to prevent abuse
        if urls.count > 10 {
            throw ToolError.invalidArguments("Too many URLs (\(urls.count)). Maximum is 10 URLs per request.")
        }

        // Parse and validate max_characters
        var maxCharacters = 5000
        if let m = args["max_characters"] as? Int {
            if m < 100 || m > 50000 {
                throw ToolError.invalidArguments("max_characters must be between 100 and 50000 (got \(m))")
            }
            maxCharacters = m
        }

        // Parse livecrawl with validation
        let livecrawlStr = args["livecrawl"] as? String ?? "fallback"
        guard let livecrawl = LivecrawlMode(rawValue: livecrawlStr) else {
            throw ToolError.invalidArguments("Invalid livecrawl '\(livecrawlStr)'. Must be one of: fallback, preferred, always")
        }

        // Fetch contents
        let results = try await exaClient.getContents(
            urls: urls,
            maxCharacters: maxCharacters,
            livecrawl: livecrawl
        )

        // Format results for the AI
        if results.isEmpty {
            return "No content could be fetched from the provided URL(s)."
        }

        var output = "Page contents for \(urls.count) URL(s):\n"
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
            } else {
                output += "\n[No text content available]\n"
            }

            output += "\n" + String(repeating: "-", count: 60) + "\n\n"
        }

        return output
    }
}
