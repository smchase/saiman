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
    let createdAt: Date

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        role: MessageRole,
        content: String,
        toolCalls: [ToolCall]? = nil,
        attachments: [Attachment]? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.createdAt = createdAt
    }
}

// Extension for converting to Bedrock API format
extension Message {
    func toBedrockFormat() -> [String: Any] {
        var dict: [String: Any] = [
            "role": role == .user ? "user" : "assistant"
        ]

        // Check if we need array format (tool calls, attachments, or complex content)
        let hasToolCalls = toolCalls != nil && !toolCalls!.isEmpty
        let hasAttachments = role == .user && attachments != nil && !attachments!.isEmpty

        if hasToolCalls || hasAttachments {
            var contentArray: [[String: Any]] = []

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
