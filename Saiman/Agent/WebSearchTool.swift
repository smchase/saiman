import Foundation

/// Web search tool powered by Exa AI.
/// Allows the agent to search the web for current information.
final class WebSearchTool: Tool {
    let name = "web_search"

    let description = """
        Search the web for information. Use this when you need current information, \
        facts you're uncertain about, or to research a topic.

        Choose depth based on your needs:
        - "quick": Fast factual lookups (5 results, brief content). Use for simple facts, \
        definitions, current events.
        - "deep": Comprehensive research (10 results, full content). Use for complex questions, \
        analysis requiring multiple sources, technical/legal topics.

        For complex topics, make multiple searches with different angles rather than one broad search. \
        Be specific in your queries - include relevant terms, dates, or source types in the query text.
        """

    let parameters: [ToolParameter] = [
        ToolParameter(
            name: "query",
            type: .string,
            description: "The search query. Be specific and targeted for better results. Include relevant context like dates, technical terms, or source types."
        ),
        ToolParameter(
            name: "depth",
            type: .string,
            description: "Search depth: 'quick' for fast factual lookups, 'deep' for comprehensive research requiring multiple detailed sources.",
            required: false,
            enumValues: ["quick", "deep"]
        )
    ]

    private let exaClient = ExaClient()

    func execute(arguments: String) async throws -> String {
        // Parse arguments
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = args["query"] as? String else {
            throw ToolError.invalidArguments("Missing required 'query' parameter")
        }

        // Parse depth (default to quick)
        let depthString = args["depth"] as? String ?? "quick"
        let depth: SearchDepth = depthString == "deep" ? .deep : .quick

        // Execute search
        let results = try await exaClient.search(query: query, depth: depth)

        // Format results for the AI
        if results.isEmpty {
            return "No results found for query: \(query)"
        }

        var output = "Search results for: \(query) [depth: \(depthString), \(results.count) results]\n"
        output += "=" .padding(toLength: 60, withPad: "=", startingAt: 0) + "\n\n"

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

            output += "\n" + "-" .padding(toLength: 60, withPad: "-", startingAt: 0) + "\n\n"
        }

        return output
    }
}
