import Foundation

// MARK: - Eval Framework

struct EvalResult: Sendable {
    let name: String
    let passed: Bool
    let details: String
    let searchCount: Int
    let responseLength: Int
}

struct EvalContext {
    let response: String
    let toolCalls: [ToolCall]
    let question: String

    var responseLength: Int { response.count }
    var deepSearchCount: Int { toolCalls.filter { $0.arguments.contains("\"depth\":\"deep\"") }.count }
    var quickSearchCount: Int {
        toolCalls.filter {
            $0.name == "web_search" && !$0.arguments.contains("\"depth\":\"deep\"")
        }.count
    }
    var totalSearchCount: Int { toolCalls.filter { $0.name == "web_search" }.count }
}

// MARK: - Eval Definition

struct Eval: Sendable {
    let name: String
    let question: String
    let assertions: @Sendable (EvalContext) -> (Bool, String)
}

// MARK: - Eval Runner

actor EvalRunner {
    private var results: [EvalResult] = []

    func runAllEvals() async {
        let startTime = Date()

        print("\n" + "=".repeated(60))
        print("  Running Evals (Parallel)")
        print("=".repeated(60) + "\n")

        let evals = buildEvals()

        // Run all evals in parallel
        await withTaskGroup(of: EvalResult.self) { group in
            for eval in evals {
                group.addTask {
                    await self.runSingleEval(eval)
                }
            }

            for await result in group {
                await addResult(result)
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        await printSummary(elapsed: elapsed)
    }

    private func addResult(_ result: EvalResult) {
        results.append(result)
    }

    private func runSingleEval(_ eval: Eval) async -> EvalResult {
        let ctx = await askAndCapture(eval.question)
        let (passed, message) = eval.assertions(ctx)

        return EvalResult(
            name: eval.name,
            passed: passed,
            details: message,
            searchCount: ctx.totalSearchCount,
            responseLength: ctx.responseLength
        )
    }

    private func printSummary(elapsed: TimeInterval) {
        // Sort by name for consistent output
        let sortedResults = results.sorted { $0.name < $1.name }

        print("\n" + "-".repeated(60))
        print("Results:")
        print("-".repeated(60))

        for result in sortedResults {
            let icon = result.passed ? "✅" : "❌"
            let stats = "(searches: \(result.searchCount), len: \(result.responseLength))"
            print("\(icon) \(result.name) \(stats)")
            if !result.passed {
                print("   └─ \(result.details)")
            }
        }

        let passed = results.filter { $0.passed }.count
        let total = results.count

        print("\n" + "=".repeated(60))
        print("  Summary: \(passed)/\(total) passed in \(String(format: "%.1f", elapsed))s")
        print("=".repeated(60))
    }

    private func buildEvals() -> [Eval] {
        return [
            // === NO SEARCH REQUIRED ===
            Eval(name: "Basic Math", question: "What is 25 * 4?") { ctx in
                if ctx.totalSearchCount > 0 { return (false, "Should not search for math") }
                if ctx.responseLength > 300 { return (false, "Math answer too long") }
                if !ctx.response.contains("100") { return (false, "Wrong answer") }
                return (true, "OK")
            },

            Eval(name: "Basic Geography", question: "What is the capital of Japan?") { ctx in
                if ctx.totalSearchCount > 0 { return (false, "Should not search for basic geography") }
                if ctx.responseLength > 400 { return (false, "Answer too long") }
                if !ctx.response.lowercased().contains("tokyo") { return (false, "Should say Tokyo") }
                return (true, "OK")
            },

            Eval(name: "Basic Science", question: "How many planets are in our solar system?") { ctx in
                if ctx.totalSearchCount > 0 { return (false, "Should not search for basic science") }
                if !ctx.response.contains("8") { return (false, "Should say 8 planets") }
                return (true, "OK")
            },

            Eval(name: "Code Snippet", question: "Show me a Python function to check if a number is prime") { ctx in
                if ctx.totalSearchCount > 0 { return (false, "Should not search for basic code") }
                if !ctx.response.contains("def ") { return (false, "Should show function") }
                return (true, "OK")
            },

            // === QUICK SEARCH REQUIRED ===
            Eval(name: "Current Price", question: "What is the current price of Bitcoin?") { ctx in
                if ctx.totalSearchCount == 0 { return (false, "Should search for current price") }
                if ctx.deepSearchCount > 0 { return (false, "Price check should use quick, not deep") }
                return (true, "OK")
            },

            Eval(name: "Current Weather", question: "What's the weather in London right now?") { ctx in
                if ctx.totalSearchCount == 0 { return (false, "Should search for weather") }
                if ctx.deepSearchCount > 0 { return (false, "Weather should use quick search") }
                if ctx.responseLength > 1200 { return (false, "Weather should be concise") }
                return (true, "OK")
            },

            Eval(name: "Recent News", question: "What happened in tech news today?") { ctx in
                if ctx.totalSearchCount == 0 { return (false, "Should search for news") }
                return (true, "OK")
            },

            // === DEEP SEARCH REQUIRED ===
            Eval(name: "Technical Comparison", question: "What are the key differences between PostgreSQL and MySQL for enterprise use?") { ctx in
                if ctx.deepSearchCount == 0 { return (false, "Should use deep search for comparison") }
                if ctx.responseLength < 800 { return (false, "Comparison should be comprehensive") }
                return (true, "OK")
            },

            Eval(name: "Research Topic", question: "What are the latest advancements in quantum computing in 2024?") { ctx in
                if ctx.deepSearchCount == 0 { return (false, "Should use deep search for research") }
                if ctx.responseLength < 600 { return (false, "Research should be detailed") }
                return (true, "OK")
            },

            // === RESPONSE LENGTH CHECKS ===
            Eval(name: "Short Answer", question: "What year did World War 2 end?") { ctx in
                if ctx.totalSearchCount > 0 { return (false, "Should not search for historical fact") }
                if ctx.responseLength > 300 { return (false, "Should be a short answer") }
                if !ctx.response.contains("1945") { return (false, "Should mention 1945") }
                return (true, "OK")
            },

            Eval(name: "Detailed Explanation", question: "Explain how neural networks learn through backpropagation") { ctx in
                if ctx.responseLength < 500 { return (false, "Technical explanation should be detailed") }
                if !ctx.response.lowercased().contains("gradient") { return (false, "Should mention gradients") }
                return (true, "OK")
            },
        ]
    }
}

// MARK: - Test Execution

@MainActor
func askAndCapture(_ question: String) async -> EvalContext {
    let agentLoop = AgentLoop()
    let conversationId = UUID()

    let userMessage = Message(
        conversationId: conversationId,
        role: .user,
        content: question
    )

    return await withCheckedContinuation { continuation in
        agentLoop.run(messages: [userMessage]) { response, toolCalls in
            let ctx = EvalContext(
                response: response,
                toolCalls: toolCalls,
                question: question
            )
            continuation.resume(returning: ctx)
        }
    }
}

// MARK: - String Extension

extension String {
    func repeated(_ times: Int) -> String {
        return String(repeating: self, count: times)
    }
}
