import Foundation

// MARK: - Reddit API Types

struct RedditThread {
    let title: String
    let selftext: String
    let author: String
    let score: Int
    let numComments: Int
    let subreddit: String
    let createdUtc: Date
    let url: String
    let comments: [RedditComment]
}

struct RedditComment {
    let author: String
    let body: String
    let score: Int
    let depth: Int
    let replies: [RedditComment]
}

// MARK: - Reddit Client

final class RedditClient {
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// Fetch a Reddit thread with comments
    func fetchThread(url: String) async throws -> RedditThread {
        let jsonUrl = normalizeUrl(url)

        guard let requestUrl = URL(string: jsonUrl) else {
            Logger.shared.error("Reddit: Invalid URL format: \(url)")
            throw RedditError.parseError("Invalid URL format")
        }

        var request = URLRequest(url: requestUrl)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            Logger.shared.error("Reddit: Network error for \(url): \(error.localizedDescription)")
            throw RedditError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.shared.error("Reddit: Invalid response type for \(url)")
            throw RedditError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 404:
            Logger.shared.error("Reddit: Thread not found (404): \(url)")
            throw RedditError.threadNotFound(url)
        case 429:
            Logger.shared.error("Reddit: Rate limited (429)")
            throw RedditError.rateLimited
        case 403:
            Logger.shared.error("Reddit: Forbidden (403) - thread may be private: \(url)")
            throw RedditError.apiError(statusCode: 403)
        default:
            Logger.shared.error("Reddit: API error (\(httpResponse.statusCode)) for \(url)")
            throw RedditError.apiError(statusCode: httpResponse.statusCode)
        }

        do {
            return try parseThread(data: data, originalUrl: url)
        } catch {
            Logger.shared.error("Reddit: Parse error for \(url): \(error.localizedDescription)")
            throw error
        }
    }

    /// Fetch multiple threads in parallel
    func fetchThreads(urls: [String]) async throws -> [Result<RedditThread, Error>] {
        await withTaskGroup(of: (Int, Result<RedditThread, Error>).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        let thread = try await self.fetchThread(url: url)
                        return (index, .success(thread))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            var results = [(Int, Result<RedditThread, Error>)]()
            for await result in group {
                results.append(result)
            }

            // Sort by original order
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    // MARK: - Private Methods

    /// Normalize URL to Reddit JSON API format
    private func normalizeUrl(_ url: String) -> String {
        var cleanUrl = url

        // Remove query params and trailing slashes
        if let queryIndex = cleanUrl.firstIndex(of: "?") {
            cleanUrl = String(cleanUrl[..<queryIndex])
        }
        while cleanUrl.hasSuffix("/") {
            cleanUrl.removeLast()
        }

        // Remove .json if already present
        if cleanUrl.hasSuffix(".json") {
            cleanUrl = String(cleanUrl.dropLast(5))
        }

        // Add .json and sort=top
        return cleanUrl + ".json?sort=top"
    }

    /// Parse Reddit JSON response into RedditThread
    private func parseThread(data: Data, originalUrl: String) throws -> RedditThread {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              json.count >= 2,
              let postData = json[0]["data"] as? [String: Any],
              let postChildren = postData["children"] as? [[String: Any]],
              let firstPost = postChildren.first,
              let post = firstPost["data"] as? [String: Any] else {
            throw RedditError.parseError("Failed to parse thread structure")
        }

        // Parse post data
        let title = post["title"] as? String ?? "Untitled"
        let selftext = post["selftext"] as? String ?? ""
        let author = post["author"] as? String ?? "[deleted]"
        let score = post["score"] as? Int ?? 0
        let numComments = post["num_comments"] as? Int ?? 0
        let subreddit = post["subreddit"] as? String ?? "unknown"
        let createdUtc = Date(timeIntervalSince1970: post["created_utc"] as? Double ?? 0)

        // Parse comments
        var comments: [RedditComment] = []
        if let commentsData = json[1]["data"] as? [String: Any],
           let commentChildren = commentsData["children"] as? [[String: Any]] {
            comments = parseComments(commentChildren, depth: 0, maxTopLevel: 20)
        }

        return RedditThread(
            title: title,
            selftext: selftext,
            author: author,
            score: score,
            numComments: numComments,
            subreddit: subreddit,
            createdUtc: createdUtc,
            url: originalUrl,
            comments: comments
        )
    }

    /// Recursively parse comments with depth limits
    /// - maxTopLevel: Max top-level comments (20)
    /// - maxReplies: Max direct replies per comment (5)
    /// - maxDepth: Max reply depth (3)
    private func parseComments(_ children: [[String: Any]], depth: Int, maxTopLevel: Int = 20, totalLimit: inout Int) -> [RedditComment] {
        guard depth < 3, totalLimit > 0 else { return [] }

        var comments: [RedditComment] = []
        let limit = depth == 0 ? maxTopLevel : (depth == 1 ? 5 : 2)

        for child in children.prefix(limit) {
            guard totalLimit > 0,
                  child["kind"] as? String == "t1",
                  let data = child["data"] as? [String: Any] else {
                continue
            }

            let author = data["author"] as? String ?? "[deleted]"
            let body = data["body"] as? String ?? ""
            let score = data["score"] as? Int ?? 0

            // Skip deleted/removed comments
            if author == "[deleted]" && (body == "[deleted]" || body == "[removed]") {
                continue
            }

            totalLimit -= 1

            // Parse replies recursively
            var replies: [RedditComment] = []
            if let repliesData = data["replies"] as? [String: Any],
               let repliesDataInner = repliesData["data"] as? [String: Any],
               let replyChildren = repliesDataInner["children"] as? [[String: Any]] {
                replies = parseComments(replyChildren, depth: depth + 1, totalLimit: &totalLimit)
            }

            comments.append(RedditComment(
                author: author,
                body: body,
                score: score,
                depth: depth,
                replies: replies
            ))
        }

        return comments
    }

    /// Helper overload for initial call
    private func parseComments(_ children: [[String: Any]], depth: Int, maxTopLevel: Int) -> [RedditComment] {
        var totalLimit = 100  // Safety cap
        return parseComments(children, depth: depth, maxTopLevel: maxTopLevel, totalLimit: &totalLimit)
    }
}

// MARK: - Errors

enum RedditError: Error, LocalizedError {
    case invalidResponse
    case threadNotFound(String)
    case rateLimited
    case apiError(statusCode: Int)
    case parseError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Reddit. The thread may have been deleted or made private."
        case .threadNotFound(let url):
            return "Thread not found: \(url). It may have been deleted or the URL is incorrect."
        case .rateLimited:
            return "Reddit rate limit exceeded. Wait a few seconds before retrying, or reduce the number of threads being fetched at once."
        case .apiError(let statusCode):
            return "Reddit API error (HTTP \(statusCode)). Try again or use fewer URLs."
        case .parseError(let message):
            return "Failed to parse Reddit response: \(message). The thread format may be unsupported."
        case .networkError(let message):
            return "Network error fetching Reddit: \(message)"
        }
    }
}
