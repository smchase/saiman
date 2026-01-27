import Foundation

/// Reddit read tool for fetching full thread content.
/// Uses Reddit's .json API to get posts and comments.
final class RedditReadTool: Tool {
    let name = "reddit_read"

    let description = """
        Fetch full content from Reddit threads including the post and top comments. \
        Use after reddit_search to read threads you want to explore in detail.

        Returns: Post content, metadata (score, author, date), and top comments with replies.
        """

    let parameters: [ToolParameter] = [
        ToolParameter(
            name: "urls",
            type: .array,
            description: "Reddit URL or array of URLs to read."
        )
    ]

    private let redditClient = RedditClient()

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
            throw ToolError.invalidArguments("Missing required 'urls' parameter.")
        }

        guard !urls.isEmpty else {
            throw ToolError.invalidArguments("URLs array cannot be empty.")
        }

        // Validate URLs are Reddit URLs
        for url in urls {
            guard url.contains("reddit.com") else {
                throw ToolError.invalidArguments("'\(url)' is not a Reddit URL.")
            }
        }

        // Limit number of URLs
        if urls.count > 10 {
            throw ToolError.invalidArguments("Too many URLs (\(urls.count)). Maximum is 10 per request.")
        }

        // Fetch threads
        let results = try await redditClient.fetchThreads(urls: urls)

        // Format output
        var output = ""

        for (index, result) in results.enumerated() {
            if index > 0 {
                output += "\n" + String(repeating: "=", count: 60) + "\n\n"
            }

            switch result {
            case .success(let thread):
                output += formatThread(thread)
            case .failure(let error):
                output += "Error fetching \(urls[index]): \(error.localizedDescription)\n"
            }
        }

        return output
    }

    /// Format a Reddit thread for display
    private func formatThread(_ thread: RedditThread) -> String {
        var output = "Reddit Thread: \(thread.title)\n"
        output += String(repeating: "=", count: 60) + "\n"

        // Metadata line
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, yyyy"
        let dateStr = dateFormatter.string(from: thread.createdUtc)

        output += "r/\(thread.subreddit) | Posted by u/\(thread.author) | \(dateStr) | "
        output += "Score: \(thread.score) | \(thread.numComments) comments\n\n"

        // Post content
        if !thread.selftext.isEmpty {
            output += thread.selftext + "\n"
        } else {
            output += "[Link post - no text content]\n"
        }

        // Comments
        if !thread.comments.isEmpty {
            output += "\n" + String(repeating: "-", count: 60) + "\n"
            output += "TOP COMMENTS\n"
            output += String(repeating: "-", count: 60) + "\n\n"

            for comment in thread.comments {
                output += formatComment(comment)
            }
        }

        return output
    }

    /// Format a comment with its replies
    private func formatComment(_ comment: RedditComment, indent: String = "") -> String {
        var output = ""

        // Comment header with score and author
        output += "\(indent)[\(comment.score) pts] u/\(comment.author)\n"

        // Comment body - indent each line
        let bodyLines = comment.body.components(separatedBy: "\n")
        for line in bodyLines {
            output += "\(indent)\(line)\n"
        }
        output += "\n"

        // Replies with increased indent
        for reply in comment.replies {
            output += formatComment(reply, indent: indent + "    ")
        }

        return output
    }
}
