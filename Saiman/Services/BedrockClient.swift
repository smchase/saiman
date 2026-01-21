import Foundation
import CryptoKit

// MARK: - Bedrock Response Types

struct BedrockResponse: Codable {
    let id: String?
    let type: String?
    let role: String?
    let content: [ContentBlock]?
    let stopReason: String?
    let usage: UsageData?

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, usage
        case stopReason = "stop_reason"
    }
}

struct UsageData: Codable {
    let inputTokens: Int
    let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct ContentBlock: Codable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: [String: AnyCodable]?
    // Extended thinking fields
    let thinking: String?
    let signature: String?
    // Redacted thinking
    let data: String?
}

// MARK: - Thinking Block

struct ThinkingBlock: Codable {
    let type: String  // "thinking" or "redacted_thinking"
    let thinking: String?
    let signature: String?
    let data: String?  // For redacted thinking
}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String:
            try container.encode(string)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Agent Response

struct AgentResponse {
    let text: String
    let toolCalls: [ToolCall]
    let thinkingBlocks: [ThinkingBlock]
    let stopReason: String?
    let usage: UsageData?
}

// MARK: - Tool Choice

enum ToolChoice {
    case auto           // Let Claude decide whether to use tools
    case any            // Claude must use at least one tool
    case tool(String)   // Claude must use a specific tool

    func toDict() -> [String: Any] {
        switch self {
        case .auto:
            return ["type": "auto"]
        case .any:
            return ["type": "any"]
        case .tool(let name):
            return ["type": "tool", "name": name]
        }
    }
}

// MARK: - Bedrock Client

final class BedrockClient {
    private let config = Config.shared

    // Custom session with longer timeout for extended thinking
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // 5 minutes for thinking
        config.timeoutIntervalForResource = 600 // 10 minutes total
        return URLSession(configuration: config)
    }()

    func sendMessage(
        messages: [Message],
        tools: [any Tool],
        toolChoice: ToolChoice = .auto,
        modelId: String? = nil
    ) async throws -> AgentResponse {
        let effectiveModelId = modelId ?? config.bedrockModelId
        let url = URL(string: "https://bedrock-runtime.\(config.awsRegion).amazonaws.com/model/\(effectiveModelId)/invoke")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Build request body
        let body = buildRequestBody(messages: messages, tools: tools, toolChoice: toolChoice)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Log the request
        if let apiMessages = body["messages"] as? [[String: Any]] {
            Logger.shared.logRequest(apiMessages)
        }

        // Sign request with AWS Signature V4
        request = try signRequest(request)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.shared.error("Invalid response from Bedrock API")
            throw BedrockError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.shared.error("Bedrock API error (\(httpResponse.statusCode)): \(errorBody)")
            throw BedrockError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let bedrockResponse = try JSONDecoder().decode(BedrockResponse.self, from: data)
        let agentResponse = parseResponse(bedrockResponse)

        // Log the response
        Logger.shared.logResponse(
            agentResponse.text,
            toolCalls: agentResponse.toolCalls.count,
            thinkingBlocks: agentResponse.thinkingBlocks.count
        )

        return agentResponse
    }

    private func buildRequestBody(
        messages: [Message],
        tools: [any Tool],
        toolChoice: ToolChoice
    ) -> [String: Any] {
        var body: [String: Any] = [
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 21333,
            "system": config.systemPrompt,
            // Extended thinking configuration
            "thinking": [
                "type": "enabled",
                "budget_tokens": 16000
            ]
        ]

        // Convert messages, ensuring proper alternation
        let apiMessages = ensureMessageAlternation(messages)
        body["messages"] = apiMessages

        // Add tools if available with proper tool_choice for structured output
        if !tools.isEmpty {
            // Tool definitions with strict JSON schema enforcement
            body["tools"] = tools.map { $0.toBedrockFormat() }

            // tool_choice controls how Claude uses tools:
            // - "auto": Claude decides (default)
            // - "any": Must use at least one tool
            // - "tool": Must use specific tool
            body["tool_choice"] = toolChoice.toDict()
        }

        return body
    }

    /// Ensures messages alternate properly (user/assistant/user/assistant).
    /// Claude API requires this strict alternation. This function:
    /// 1. Filters out system messages (they go in the system field)
    /// 2. Skips empty or error messages
    /// 3. Merges consecutive messages of the same role
    private func ensureMessageAlternation(_ messages: [Message]) -> [[String: Any]] {
        // Filter out system messages
        let nonSystemMessages = messages.filter { $0.role != .system }

        guard !nonSystemMessages.isEmpty else { return [] }

        var result: [[String: Any]] = []
        var currentRole: MessageRole? = nil

        for message in nonSystemMessages {
            let messageDict = message.toBedrockFormat()

            // Skip empty messages (e.g., error messages or cancelled responses)
            if let content = messageDict["content"] as? String,
               content.isEmpty || content.hasPrefix("Error:") {
                continue
            }

            // If same role as previous, merge content
            if message.role == currentRole, !result.isEmpty {
                // Merge with previous message
                var lastMessage = result.removeLast()
                let newContent = mergeContent(
                    existing: lastMessage["content"],
                    new: messageDict["content"]
                )
                lastMessage["content"] = newContent
                result.append(lastMessage)
            } else {
                // Different role - ensure alternation
                result.append(messageDict)
                currentRole = message.role
            }
        }

        return result
    }

    /// Merges content from two messages (handles both string and array formats)
    private func mergeContent(existing: Any?, new: Any?) -> Any {
        // Convert both to arrays
        let existingArray: [[String: Any]]
        let newArray: [[String: Any]]

        if let str = existing as? String {
            existingArray = str.isEmpty ? [] : [["type": "text", "text": str]]
        } else if let arr = existing as? [[String: Any]] {
            existingArray = arr
        } else {
            existingArray = []
        }

        if let str = new as? String {
            newArray = str.isEmpty ? [] : [["type": "text", "text": str]]
        } else if let arr = new as? [[String: Any]] {
            newArray = arr
        } else {
            newArray = []
        }

        return existingArray + newArray
    }

    private func parseResponse(_ response: BedrockResponse) -> AgentResponse {
        var text = ""
        var toolCalls: [ToolCall] = []
        var thinkingBlocks: [ThinkingBlock] = []

        if let content = response.content {
            for block in content {
                switch block.type {
                case "text":
                    if let blockText = block.text {
                        text += blockText
                    }
                case "thinking":
                    // Extended thinking block
                    thinkingBlocks.append(ThinkingBlock(
                        type: "thinking",
                        thinking: block.thinking,
                        signature: block.signature,
                        data: nil
                    ))
                case "redacted_thinking":
                    // Redacted thinking block (encrypted for safety)
                    thinkingBlocks.append(ThinkingBlock(
                        type: "redacted_thinking",
                        thinking: nil,
                        signature: nil,
                        data: block.data
                    ))
                case "tool_use":
                    if let id = block.id, let name = block.name {
                        let arguments: String
                        if let input = block.input {
                            let inputDict = input.mapValues { $0.value }
                            if let data = try? JSONSerialization.data(withJSONObject: inputDict),
                               let str = String(data: data, encoding: .utf8) {
                                arguments = str
                            } else {
                                arguments = "{}"
                            }
                        } else {
                            arguments = "{}"
                        }
                        toolCalls.append(ToolCall(id: id, name: name, arguments: arguments, result: nil))
                    }
                default:
                    break
                }
            }
        }

        return AgentResponse(text: text, toolCalls: toolCalls, thinkingBlocks: thinkingBlocks, stopReason: response.stopReason, usage: response.usage)
    }

    // MARK: - AWS Signature V4

    private func signRequest(_ request: URLRequest) throws -> URLRequest {
        var signedRequest = request
        let date = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = dateFormatter.string(from: date)

        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: date)

        signedRequest.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")

        if let sessionToken = config.awsSessionToken {
            signedRequest.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        let host = signedRequest.url!.host!
        signedRequest.setValue(host, forHTTPHeaderField: "Host")

        // Canonical request
        let method = signedRequest.httpMethod!
        // URI encode the path for signature calculation (keep slashes and safe characters)
        let rawPath = signedRequest.url!.path.isEmpty ? "/" : signedRequest.url!.path
        let allowedCharacters = CharacterSet(charactersIn: "/").union(.alphanumerics).union(CharacterSet(charactersIn: "-._~"))
        let canonicalUri = rawPath.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? rawPath
        let canonicalQueryString = signedRequest.url!.query ?? ""

        let headers = signedRequest.allHTTPHeaderFields ?? [:]
        let signedHeaders = headers.keys.map { $0.lowercased() }.sorted().joined(separator: ";")
        let canonicalHeaders = headers.keys.sorted { $0.lowercased() < $1.lowercased() }
            .map { "\($0.lowercased()):\(headers[$0]!.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n") + "\n"

        let payloadHash = sha256Hash(signedRequest.httpBody ?? Data())

        let canonicalRequest = [
            method,
            canonicalUri,
            canonicalQueryString,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        // String to sign
        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = "\(dateStamp)/\(config.awsRegion)/bedrock/aws4_request"
        let stringToSign = [
            algorithm,
            amzDate,
            credentialScope,
            sha256Hash(canonicalRequest.data(using: .utf8)!)
        ].joined(separator: "\n")

        // Signature
        let signature = calculateSignature(
            secretKey: config.awsSecretAccessKey,
            dateStamp: dateStamp,
            regionName: config.awsRegion,
            serviceName: "bedrock",
            stringToSign: stringToSign
        )

        // Authorization header
        let authorization = "\(algorithm) Credential=\(config.awsAccessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        signedRequest.setValue(authorization, forHTTPHeaderField: "Authorization")

        return signedRequest
    }

    private func sha256Hash(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(signature)
    }

    private func calculateSignature(secretKey: String, dateStamp: String, regionName: String, serviceName: String, stringToSign: String) -> String {
        let kSecret = Data("AWS4\(secretKey)".utf8)
        let kDate = hmacSHA256(key: kSecret, data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(regionName.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data(serviceName.utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
        return signature.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

enum BedrockError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Bedrock API"
        case .apiError(let statusCode, let message):
            return "Bedrock API error (\(statusCode)): \(message)"
        }
    }
}
