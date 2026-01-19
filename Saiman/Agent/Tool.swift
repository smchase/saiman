import Foundation

// MARK: - Tool Protocol

/// Protocol defining a tool that can be used by the AI agent.
/// Implement this protocol to add new capabilities to the agent.
protocol Tool {
    /// Unique identifier for the tool
    var name: String { get }

    /// Human-readable description of what the tool does
    var description: String { get }

    /// Parameters the tool accepts
    var parameters: [ToolParameter] { get }

    /// Execute the tool with the given arguments
    /// - Parameter arguments: JSON-encoded arguments matching the parameter schema
    /// - Returns: The result of the tool execution as a string
    func execute(arguments: String) async throws -> String
}

// MARK: - Tool Parameter

struct ToolParameter {
    let name: String
    let type: ParameterType
    let description: String
    let required: Bool
    let enumValues: [String]?  // For string enums

    enum ParameterType: String {
        case string
        case integer
        case number
        case boolean
        case array
        case object
    }

    init(name: String, type: ParameterType, description: String, required: Bool = true, enumValues: [String]? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.enumValues = enumValues
    }
}

// MARK: - Tool Extension for Bedrock Format

extension Tool {
    /// Converts the tool definition to Bedrock/Claude API format with strict schema enforcement.
    /// Uses JSON Schema with additionalProperties: false to ensure the model only provides
    /// exactly the parameters defined in the schema.
    func toBedrockFormat() -> [String: Any] {
        var properties: [String: Any] = [:]
        var requiredParams: [String] = []

        for param in parameters {
            var paramSchema: [String: Any] = [
                "type": param.type.rawValue,
                "description": param.description
            ]

            // Add enum constraint if specified (forces model to pick from valid values)
            if let enumValues = param.enumValues {
                paramSchema["enum"] = enumValues
            }

            // Add additional constraints based on type for stricter validation
            switch param.type {
            case .array:
                // For arrays, could specify items type if needed
                break
            case .object:
                // For nested objects, prevent additional properties
                paramSchema["additionalProperties"] = false
            default:
                break
            }

            properties[param.name] = paramSchema

            if param.required {
                requiredParams.append(param.name)
            }
        }

        return [
            "name": name,
            "description": description,
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": requiredParams,
                // Strict mode: only allow defined properties, no extra fields
                "additionalProperties": false
            ]
        ]
    }
}

// MARK: - Tool Registry

/// Registry for managing available tools.
/// Add new tools here to make them available to the agent.
final class ToolRegistry {
    private var tools: [String: any Tool] = [:]

    init() {
        // Register default tools
        register(WebSearchTool())
    }

    func register(_ tool: any Tool) {
        tools[tool.name] = tool
    }

    func unregister(name: String) {
        tools.removeValue(forKey: name)
    }

    func get(name: String) -> (any Tool)? {
        tools[name]
    }

    var allTools: [any Tool] {
        Array(tools.values)
    }

    func execute(toolCall: ToolCall) async throws -> String {
        guard let tool = tools[toolCall.name] else {
            throw ToolError.unknownTool(toolCall.name)
        }
        return try await tool.execute(arguments: toolCall.arguments)
    }
}

// MARK: - Tool Errors

enum ToolError: Error, LocalizedError {
    case unknownTool(String)
    case invalidArguments(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        case .executionFailed(let message):
            return "Tool execution failed: \(message)"
        }
    }
}
