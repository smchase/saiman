import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct ToolCall: Codable, Identifiable {
    let id: String
    let name: String
    let arguments: String
    var result: String?
    var isError: Bool = false
}

struct Message: Identifiable, Codable {
    let id: UUID
    let conversationId: UUID
    let role: MessageRole
    let content: String
    var toolCalls: [ToolCall]?
    var attachments: [Attachment]?
    var thinkingBlocks: [ThinkingBlock]?
    var toolUsageSummary: String?  // Display-only, not sent to API
    let createdAt: Date

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        role: MessageRole,
        content: String,
        toolCalls: [ToolCall]? = nil,
        attachments: [Attachment]? = nil,
        thinkingBlocks: [ThinkingBlock]? = nil,
        toolUsageSummary: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.thinkingBlocks = thinkingBlocks
        self.toolUsageSummary = toolUsageSummary
        self.createdAt = createdAt
    }
}

// Extension for converting to Bedrock API format
extension Message {
    func toBedrockFormat() -> [String: Any] {
        var dict: [String: Any] = [
            "role": role == .user ? "user" : "assistant"
        ]

        // Check if we need array format (tool calls, attachments, thinking blocks, or complex content)
        let hasToolCalls = toolCalls != nil && !toolCalls!.isEmpty
        let hasAttachments = role == .user && attachments != nil && !attachments!.isEmpty
        let hasThinkingBlocks = role == .assistant && thinkingBlocks != nil && !thinkingBlocks!.isEmpty

        if hasToolCalls || hasAttachments || hasThinkingBlocks {
            var contentArray: [[String: Any]] = []

            // For assistant messages: thinking blocks MUST come first
            if role == .assistant, let thinkingBlocks = thinkingBlocks {
                for block in thinkingBlocks {
                    if block.type == "thinking" {
                        var thinkingDict: [String: Any] = ["type": "thinking"]
                        if let thinking = block.thinking {
                            thinkingDict["thinking"] = thinking
                        }
                        if let signature = block.signature {
                            thinkingDict["signature"] = signature
                        }
                        contentArray.append(thinkingDict)
                    } else if block.type == "redacted_thinking" {
                        var redactedDict: [String: Any] = ["type": "redacted_thinking"]
                        if let data = block.data {
                            redactedDict["data"] = data
                        }
                        contentArray.append(redactedDict)
                    }
                }
            }

            // For user messages: add images first (Claude processes them in order)
            if role == .user, let attachments = attachments {
                for attachment in attachments {
                    if let imageData = attachment.loadImageData() {
                        contentArray.append([
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": attachment.mimeType,
                                "data": imageData.base64EncodedString()
                            ]
                        ])
                    }
                }
            }

            // Add text content
            if !content.isEmpty {
                contentArray.append(["type": "text", "text": content])
            }

            // Handle tool calls based on role
            if let toolCalls = toolCalls, !toolCalls.isEmpty {
                // Role determines block type:
                // - Assistant messages can ONLY contain tool_use blocks
                // - User messages can ONLY contain tool_result blocks
                if role == .assistant {
                    // Assistant messages: tool_use blocks (no results)
                    for call in toolCalls {
                        contentArray.append([
                            "type": "tool_use",
                            "id": call.id,
                            "name": call.name,
                            "input": (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) ?? [:]
                        ])
                    }
                } else {
                    // User messages: tool_result blocks
                    for call in toolCalls {
                        var resultBlock: [String: Any] = [
                            "type": "tool_result",
                            "tool_use_id": call.id,
                            "content": call.result ?? ""
                        ]
                        // Include is_error if the tool failed - helps Claude handle failures
                        if call.isError {
                            resultBlock["is_error"] = true
                        }
                        contentArray.append(resultBlock)
                    }
                }
            }

            dict["content"] = contentArray
        } else {
            // Simple text content
            dict["content"] = content
        }

        return dict
    }
}

// MARK: - Tool Usage Summary

extension Message {
    /// Generate a tool usage summary from an array of tool calls.
    /// Returns nil if no tools were used.
    /// Format: "🛠️ 2 web searches · 1 page read · 3 Reddit searches · 2 Reddit threads read"
    static func generateToolUsageSummary(from toolCalls: [ToolCall]) -> String? {
        guard !toolCalls.isEmpty else { return nil }

        // Count tool usage (order: most general to least general)
        // For tools that batch URLs, count the actual number of items
        var webSearches = 0
        var pagesRead = 0
        var redditSearches = 0
        var redditThreadsRead = 0

        for call in toolCalls {
            switch call.name {
            case "web_search":
                webSearches += 1
            case "get_page_contents":
                // Count actual URLs in the batch
                pagesRead += countUrlsInArguments(call.arguments)
            case "reddit_search":
                redditSearches += 1
            case "reddit_read":
                // Count actual URLs in the batch
                redditThreadsRead += countUrlsInArguments(call.arguments)
            default:
                break
            }
        }

        // Build summary parts (only non-zero counts)
        var parts: [String] = []

        if webSearches > 0 {
            parts.append(webSearches == 1 ? "1 web search" : "\(webSearches) web searches")
        }
        if pagesRead > 0 {
            parts.append(pagesRead == 1 ? "1 page read" : "\(pagesRead) pages read")
        }
        if redditSearches > 0 {
            parts.append(redditSearches == 1 ? "1 Reddit search" : "\(redditSearches) Reddit searches")
        }
        if redditThreadsRead > 0 {
            parts.append(redditThreadsRead == 1 ? "1 Reddit thread read" : "\(redditThreadsRead) Reddit threads read")
        }

        guard !parts.isEmpty else { return nil }

        return "🛠️ " + parts.joined(separator: ", ")
    }

    /// Count the number of URLs in a tool call's arguments.
    /// Handles both single URL strings and arrays of URLs.
    private static func countUrlsInArguments(_ arguments: String) -> Int {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 1  // Fallback to 1 if parsing fails
        }

        if let urlArray = args["urls"] as? [String] {
            return urlArray.count
        } else if args["urls"] is String {
            return 1
        }

        return 1  // Fallback
    }
}
