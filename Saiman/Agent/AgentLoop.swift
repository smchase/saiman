import Foundation

// MARK: - Agent State

enum AgentState {
    case idle
    case thinking
    case executingTool(String)
    case responding
    case error(Error)
    case cancelled
}

// MARK: - Agent Loop

/// The core agent loop that orchestrates LLM calls and tool execution.
/// Supports multiple tool calls per turn and iterates until the model provides a final response.
@MainActor
final class AgentLoop: ObservableObject {
    @Published private(set) var state: AgentState = .idle
    @Published private(set) var currentResponse: String = ""
    @Published private(set) var toolCallCount: Int = 0

    private let bedrockClient = BedrockClient()
    private let toolRegistry = ToolRegistry()
    private let config = Config.shared

    private var currentTask: Task<Void, Never>?

    /// Run the agent loop with the given messages.
    /// - Parameters:
    ///   - messages: The conversation history including the new user message
    ///   - onComplete: Called with the final assistant response and any tool calls made
    func run(
        messages: [Message],
        onComplete: @escaping (String, [ToolCall]) -> Void
    ) {
        cancel() // Cancel any existing run

        currentTask = Task {
            await executeLoop(messages: messages, onComplete: onComplete)
        }
    }

    /// Cancel the current agent run
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        state = .cancelled
        currentResponse = ""
        toolCallCount = 0
    }

    private func executeLoop(
        messages: [Message],
        onComplete: @escaping (String, [ToolCall]) -> Void
    ) async {
        var workingMessages = messages
        var allToolCalls: [ToolCall] = []
        var iterations = 0

        state = .thinking
        currentResponse = ""
        toolCallCount = 0

        Logger.shared.info("AgentLoop starting with \(messages.count) messages")

        while iterations < config.maxToolCalls {
            // Check for cancellation
            if Task.isCancelled {
                state = .cancelled
                return
            }

            // Call the LLM
            let response: AgentResponse
            do {
                response = try await bedrockClient.sendMessage(
                    messages: workingMessages,
                    tools: toolRegistry.allTools
                )
                // Track token usage
                TokenTracker.shared.add(usage: response.usage)
            } catch is CancellationError {
                // Task was cancelled - exit silently without adding any message
                state = .cancelled
                return
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                // URLSession was cancelled - exit silently
                state = .cancelled
                return
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
                // Request timed out - likely due to extended thinking on complex query
                Logger.shared.error("Request timed out after 300 seconds")
                state = .error(error)
                onComplete("The request timed out. This can happen with complex reasoning tasks. Try simplifying the question or starting a new conversation.", allToolCalls)
                return
            } catch {
                Logger.shared.error("API error: \(error.localizedDescription)")
                state = .error(error)
                onComplete("Error: \(error.localizedDescription)", allToolCalls)
                return
            }

            // Update current response with any text
            if !response.text.isEmpty {
                currentResponse = response.text
            }

            // If no tool calls, we're done
            if response.toolCalls.isEmpty {
                state = .idle
                onComplete(response.text, allToolCalls)
                return
            }

            // Process tool calls
            Logger.shared.info("Processing \(response.toolCalls.count) tool calls")
            var completedToolCalls: [ToolCall] = []

            for var toolCall in response.toolCalls {
                if Task.isCancelled {
                    state = .cancelled
                    return
                }

                state = .executingTool(toolCall.name)
                toolCallCount += 1
                Logger.shared.debug("Executing tool: \(toolCall.name) with args: \(toolCall.arguments)")

                do {
                    let result = try await toolRegistry.execute(toolCall: toolCall)
                    toolCall.result = result
                    toolCall.isError = false
                    Logger.shared.debug("Tool result: \(result.prefix(200))...")
                } catch is CancellationError {
                    // Task was cancelled during tool execution - exit silently
                    state = .cancelled
                    return
                } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                    // URLSession was cancelled during tool execution - exit silently
                    state = .cancelled
                    return
                } catch {
                    toolCall.result = "Error executing tool: \(error.localizedDescription)"
                    toolCall.isError = true
                    Logger.shared.error("Tool execution failed: \(error.localizedDescription)")
                }

                completedToolCalls.append(toolCall)
                allToolCalls.append(toolCall)
            }

            // Add assistant message with tool calls and thinking blocks (no results yet)
            // Thinking blocks MUST be preserved and passed back for reasoning continuity
            let assistantMessage = Message(
                conversationId: messages.first?.conversationId ?? UUID(),
                role: .assistant,
                content: response.text,
                toolCalls: response.toolCalls,
                thinkingBlocks: response.thinkingBlocks.isEmpty ? nil : response.thinkingBlocks
            )
            workingMessages.append(assistantMessage)
            Logger.shared.debug("Added assistant message with \(response.toolCalls.count) tool_use blocks and \(response.thinkingBlocks.count) thinking blocks")

            // Add tool results as user message
            let toolResultMessage = Message(
                conversationId: messages.first?.conversationId ?? UUID(),
                role: .user,
                content: "",
                toolCalls: completedToolCalls
            )
            workingMessages.append(toolResultMessage)
            Logger.shared.debug("Added user message with \(completedToolCalls.count) tool_result blocks")

            iterations += 1
            state = .thinking
        }

        // Max iterations reached - force a final response without tools
        Logger.shared.info("Max tool calls reached (\(config.maxToolCalls)), forcing final response")
        state = .thinking

        // Add a message asking for synthesis
        let synthesisMessage = Message(
            conversationId: messages.first?.conversationId ?? UUID(),
            role: .user,
            content: "You've reached the maximum number of tool calls. Please provide your best answer based on the information gathered so far."
        )
        workingMessages.append(synthesisMessage)

        do {
            let finalResponse = try await bedrockClient.sendMessage(
                messages: workingMessages,
                tools: [] // No tools - force text response
            )
            // Track token usage
            TokenTracker.shared.add(usage: finalResponse.usage)
            let responseText = finalResponse.text.isEmpty
                ? "I was unable to complete this request - the tool call limit was reached."
                : finalResponse.text + "\n\n---\n*Note: This response may be incomplete - the tool call limit (\(config.maxToolCalls)) was reached.*"
            state = .idle
            onComplete(responseText, allToolCalls)
        } catch {
            state = .idle
            onComplete("I was unable to complete this request - the tool call limit was reached and an error occurred.", allToolCalls)
        }
    }
}

// MARK: - Convenience Extension

extension AgentLoop {
    /// Generate a title for a conversation based on its messages
    func generateTitle(for messages: [Message]) async -> String? {
        let titlePrompt = Message(
            conversationId: messages.first?.conversationId ?? UUID(),
            role: .user,
            content: "Based on this conversation, generate a very short title (3-6 words max, no quotes). Just output the title, nothing else."
        )

        var titleMessages = messages.filter { $0.role != .system }
        // Use the most recent messages to reflect current conversation direction
        if titleMessages.count > 4 {
            titleMessages = Array(titleMessages.suffix(4))
        }
        titleMessages.append(titlePrompt)

        do {
            // Use Haiku for fast, cheap title generation
            let response = try await bedrockClient.sendMessage(
                messages: titleMessages,
                tools: [],
                modelId: Config.shared.bedrockHaikuModelId
            )
            // Track token usage for title generation
            TokenTracker.shared.add(usage: response.usage)
            let title = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Ensure it's not too long
            if title.count > 50 {
                return String(title.prefix(47)) + "..."
            }
            return title.isEmpty ? nil : title
        } catch {
            return nil
        }
    }
}
