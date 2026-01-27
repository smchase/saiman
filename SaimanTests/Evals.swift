import Foundation

// MARK: - Eval Framework

struct EvalResult: Sendable {
    let name: String
    let passed: Bool
    let details: String
    let stats: String
}

struct EvalContext {
    let response: String
    let toolCalls: [ToolCall]
    let question: String

    var responseLength: Int { response.count }

    // Search analysis
    var searchCalls: [ToolCall] {
        toolCalls.filter { $0.name == "web_search" }
    }

    var totalSearchCount: Int { searchCalls.count }

    var fetchCalls: [ToolCall] {
        toolCalls.filter { $0.name == "get_page_contents" }
    }

    var redditSearchCalls: [ToolCall] {
        toolCalls.filter { $0.name == "reddit_search" }
    }

    var redditReadCalls: [ToolCall] {
        toolCalls.filter { $0.name == "reddit_read" }
    }

    // Total search activity (web_search + reddit_search)
    var totalSearchActivity: Int {
        totalSearchCount + redditSearchCalls.count
    }

    // Parse search parameters from tool calls
    func searchTypes() -> [String] {
        searchCalls.compactMap { call in
            parseArgument(call.arguments, key: "search_type") as? String
        }
    }

    func numResults() -> [Int] {
        searchCalls.compactMap { call in
            parseArgument(call.arguments, key: "num_results") as? Int
        }
    }

    func livecrawlModes() -> [String] {
        searchCalls.compactMap { call in
            parseArgument(call.arguments, key: "livecrawl") as? String
        }
    }

    func hasDeepSearch() -> Bool {
        searchTypes().contains("deep")
    }

    func hasFreshContent() -> Bool {
        let modes = livecrawlModes()
        return modes.contains("preferred") || modes.contains("always")
    }

    func maxNumResults() -> Int {
        numResults().max() ?? 5 // default is 5
    }

    private func parseArgument(_ json: String, key: String) -> Any? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict[key]
    }
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
        print("  Running Evals")
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

        // Build stats string
        var stats: [String] = []
        if ctx.totalSearchCount > 0 {
            stats.append("searches: \(ctx.totalSearchCount)")
            if !ctx.searchTypes().isEmpty {
                let types = ctx.searchTypes().joined(separator: ", ")
                stats.append("types: [\(types)]")
            }
            if ctx.maxNumResults() != 5 {
                stats.append("max_results: \(ctx.maxNumResults())")
            }
            if ctx.hasFreshContent() {
                stats.append("livecrawl: fresh")
            }
        }
        if !ctx.redditSearchCalls.isEmpty {
            stats.append("reddit_search: \(ctx.redditSearchCalls.count)")
        }
        if !ctx.redditReadCalls.isEmpty {
            stats.append("reddit_read: \(ctx.redditReadCalls.count)")
        }
        stats.append("len: \(ctx.responseLength)")

        return EvalResult(
            name: eval.name,
            passed: passed,
            details: message,
            stats: stats.joined(separator: ", ")
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
            print("\(icon) \(result.name)")
            print("   (\(result.stats))")
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
            // Tests: Model knows when NOT to search (saves cost, faster response)

            Eval(name: "No Search: Basic Math", question: "What is 15 * 8?") { ctx in
                if ctx.totalSearchCount > 0 {
                    return (false, "Should not search for arithmetic")
                }
                if !ctx.response.contains("120") {
                    return (false, "Wrong answer (expected 120)")
                }
                if ctx.responseLength > 200 {
                    return (false, "Math answer should be very concise")
                }
                return (true, "OK")
            },

            Eval(name: "No Search: Well-Known Fact", question: "What is the capital of France?") { ctx in
                if ctx.totalSearchCount > 0 {
                    return (false, "Should not search for well-known geography")
                }
                if !ctx.response.lowercased().contains("paris") {
                    return (false, "Should say Paris")
                }
                return (true, "OK")
            },

            // === SIMPLE LOOKUP ===
            // Tests: Uses search but with efficient parameters (fast/auto, few results)

            Eval(name: "Simple Lookup: Current Price", question: "What is Bitcoin trading at right now?") { ctx in
                if ctx.totalSearchCount == 0 {
                    return (false, "Should search for current price")
                }
                // Should not use deep search for a simple price lookup
                if ctx.hasDeepSearch() {
                    return (false, "Price lookup should not use deep search")
                }
                // Should request fresh content for real-time price
                if !ctx.hasFreshContent() {
                    return (false, "Current price should use livecrawl: preferred or always")
                }
                return (true, "OK")
            },

            // === CURRENT EVENTS ===
            // Tests: Uses livecrawl for time-sensitive content

            Eval(name: "Current Events: Recent News", question: "What's the top tech news from this week?") { ctx in
                if ctx.totalSearchCount == 0 {
                    return (false, "Should search for current news")
                }
                // News should request fresh content
                if !ctx.hasFreshContent() {
                    return (false, "News queries should use livecrawl: preferred")
                }
                return (true, "OK")
            },

            // === RESEARCH / DEEP SEARCH ===
            // Tests: Uses deep search and/or more results for complex queries

            Eval(name: "Research: Recent Developments", question: "What are the major new features and changes in the latest stable release of Node.js? Include version number and key highlights.") { ctx in
                if ctx.totalSearchCount == 0 {
                    return (false, "Should search for recent release info")
                }
                // Research should use deep search OR multiple results
                let usedDeep = ctx.hasDeepSearch()
                let usedManyResults = ctx.maxNumResults() >= 8
                if !usedDeep && !usedManyResults {
                    return (false, "Research should use deep search or num_results >= 8")
                }
                // Response should be comprehensive
                if ctx.responseLength < 400 {
                    return (false, "Research response should be detailed (got \(ctx.responseLength) chars)")
                }
                return (true, "OK")
            },

            // === RESPONSE CALIBRATION ===
            // Tests: Response length matches question complexity

            Eval(name: "Calibration: Short Answer", question: "What year was the first iPhone released?") { ctx in
                // Might or might not search - that's fine
                if !ctx.response.contains("2007") {
                    return (false, "Should mention 2007")
                }
                if ctx.responseLength > 300 {
                    return (false, "Simple factual question should get concise answer")
                }
                return (true, "OK")
            },

            Eval(name: "Calibration: Detailed Explanation", question: "Explain how gradient descent works in machine learning, including the intuition behind it.") { ctx in
                // Should NOT search - this is established knowledge
                if ctx.totalSearchCount > 0 {
                    return (false, "Should not search for well-established ML concepts")
                }
                // Should be thorough
                if ctx.responseLength < 400 {
                    return (false, "Technical explanation should be detailed")
                }
                // Should mention key concepts
                let lower = ctx.response.lowercased()
                if !lower.contains("gradient") || !lower.contains("loss") {
                    return (false, "Should explain core concepts (gradient, loss)")
                }
                return (true, "OK")
            },

            // === QUALITY: MULTI-SEARCH RESEARCH ===
            // Tests: Does multiple searches for complex topics requiring synthesis

            Eval(name: "Quality: Multi-Perspective Research", question: "What are the main arguments for and against remote work becoming permanent? I want perspectives from both employers and employees.") { ctx in
                // Should search - this needs current perspectives (web_search or reddit_search)
                if ctx.totalSearchActivity == 0 {
                    return (false, "Should search for current perspectives on remote work")
                }
                // Should do multiple searches or get many results for balanced view
                let thoroughResearch = ctx.totalSearchActivity >= 2 || ctx.maxNumResults() >= 8
                if !thoroughResearch {
                    return (false, "Balanced research should use multiple searches or many results")
                }
                // Response should cover both sides
                let lower = ctx.response.lowercased()
                let hasBothSides = (lower.contains("employer") || lower.contains("company") || lower.contains("business")) &&
                                   (lower.contains("employee") || lower.contains("worker"))
                if !hasBothSides {
                    return (false, "Should cover both employer and employee perspectives")
                }
                return (true, "OK")
            },

            // === QUALITY: DIRECT ANSWER ===
            // Tests: Leads with the answer, not preamble

            Eval(name: "Quality: Direct Answer", question: "What is the population of Tokyo?") { ctx in
                // This is a simple factual lookup - may or may not need search
                // Key test: answer should be direct, not buried in preamble
                let lower = ctx.response.lowercased()

                // Should contain a number (the population)
                let hasNumber = ctx.response.range(of: #"\d"#, options: .regularExpression) != nil
                if !hasNumber {
                    return (false, "Should provide a population number")
                }

                // Should NOT start with unnecessary preamble
                let badStarts = ["certainly", "great question", "i'd be happy", "sure!", "of course"]
                for phrase in badStarts {
                    if lower.hasPrefix(phrase) {
                        return (false, "Should not start with filler phrases like '\(phrase)'")
                    }
                }

                // Should be reasonably concise for a simple fact
                if ctx.responseLength > 500 {
                    return (false, "Simple factual question should get concise answer (got \(ctx.responseLength) chars)")
                }
                return (true, "OK")
            },

            // === QUALITY: HANDLES AMBIGUITY ===
            // Tests: Acknowledges uncertainty or asks for clarification on ambiguous queries

            Eval(name: "Quality: Handles Uncertainty", question: "Is GraphQL better than REST?") { ctx in
                // This is an opinion/context-dependent question
                // Good response acknowledges trade-offs rather than declaring a winner
                let lower = ctx.response.lowercased()
                let acknowledgesTradeoffs = lower.contains("depends") ||
                                           lower.contains("trade-off") ||
                                           lower.contains("tradeoff") ||
                                           lower.contains("use case") ||
                                           lower.contains("context") ||
                                           lower.contains("scenario") ||
                                           lower.contains("it varies") ||
                                           lower.contains("both have") ||
                                           lower.contains("each has") ||
                                           lower.contains("neither is") ||
                                           lower.contains("not necessarily") ||
                                           (lower.contains("pros") && lower.contains("cons")) ||
                                           (lower.contains("advantage") && lower.contains("disadvantage")) ||
                                           (lower.contains("better for") && lower.contains("worse for")) ||
                                           (lower.contains("graphql") && lower.contains("rest") && lower.contains("when"))
                if !acknowledgesTradeoffs {
                    return (false, "Should acknowledge this is context-dependent, not declare a winner")
                }
                return (true, "OK")
            },

            // === QUALITY: PREFERS USER FORUMS ===
            // Tests: Uses Reddit/forums for opinion-based queries instead of SEO spam

            Eval(name: "Quality: Prefers User Forums", question: "What's a good budget mechanical keyboard for programming?") { ctx in
                if ctx.totalSearchActivity == 0 {
                    return (false, "Should search for product recommendations")
                }
                // Using reddit_search is the ideal behavior
                if !ctx.redditSearchCalls.isEmpty {
                    return (true, "OK")
                }
                // Fallback: check if web_search query includes reddit or forum
                let queries = ctx.searchCalls.compactMap { call -> String? in
                    guard let data = call.arguments.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let query = dict["query"] as? String else { return nil }
                    return query.lowercased()
                }
                let usedForumSource = queries.contains { q in
                    q.contains("reddit") || q.contains("forum") || q.contains("community")
                }
                if !usedForumSource {
                    return (false, "Product recommendations should use reddit_search or search Reddit/forums")
                }
                return (true, "OK")
            },

            // === QUALITY: SPECIFIC NUMBERS ===
            // Tests: Provides specific data points, not vague statements

            Eval(name: "Quality: Specific Data", question: "How many monthly active users does TikTok have?") { ctx in
                if ctx.totalSearchCount == 0 {
                    return (false, "Should search for current user statistics")
                }
                // Should include actual numbers, not just "millions" or "a lot"
                let hasSpecificNumber = ctx.response.contains("billion") ||
                                       ctx.response.range(of: #"\d+\s*(million|m\b|M\b)"#, options: .regularExpression) != nil ||
                                       ctx.response.range(of: #"\d{3,}"#, options: .regularExpression) != nil
                if !hasSpecificNumber {
                    return (false, "Should provide specific user count, not vague estimates")
                }
                return (true, "OK")
            },

            // === REDDIT TOOLS ===
            // Tests: Uses reddit_search for opinion/recommendation queries

            Eval(name: "Reddit: Used for Recommendations", question: "What's the best mechanical keyboard according to Reddit?") { ctx in
                // Should use reddit_search for product recommendations
                if ctx.redditSearchCalls.isEmpty {
                    return (false, "Should use reddit_search for Reddit-specific recommendations")
                }
                // Response should mention specific keyboards
                let lower = ctx.response.lowercased()
                let hasSpecificRec = lower.contains("keyboard") || lower.contains("keychron") ||
                                    lower.contains("ducky") || lower.contains("anne pro") ||
                                    lower.contains("leopold") || lower.contains("varmilo")
                if !hasSpecificRec {
                    return (false, "Should mention specific keyboard recommendations")
                }
                return (true, "OK")
            },

            Eval(name: "Reddit: Read After Search", question: "Search Reddit for the best budget headphones and tell me what people recommend") { ctx in
                // Should use reddit_search
                if ctx.redditSearchCalls.isEmpty {
                    return (false, "Should use reddit_search first")
                }
                // Should also use reddit_read to get details
                if ctx.redditReadCalls.isEmpty {
                    return (false, "Should use reddit_read to get thread details")
                }
                // Response should include specific product recommendations
                let lower = ctx.response.lowercased()
                let hasProducts = lower.contains("headphone") || lower.contains("audio") ||
                                 lower.contains("$") || lower.contains("budget")
                if !hasProducts {
                    return (false, "Should include specific headphone recommendations")
                }
                return (true, "OK")
            },

            Eval(name: "Reddit: Not Used for Facts", question: "What is the population of Canada?") { ctx in
                // Should NOT use reddit tools for factual queries
                if !ctx.redditSearchCalls.isEmpty {
                    return (false, "Should not use reddit_search for factual lookups")
                }
                // Should contain a number
                let hasNumber = ctx.response.range(of: #"\d"#, options: .regularExpression) != nil
                if !hasNumber {
                    return (false, "Should provide a population number")
                }
                return (true, "OK")
            },

            Eval(name: "Reddit: Restaurant Recommendations", question: "What's the best ramen in San Francisco?") { ctx in
                // Should use reddit_search for restaurant recommendations
                if ctx.redditSearchCalls.isEmpty {
                    return (false, "Should use reddit_search for restaurant recommendations")
                }
                // Response should mention specific restaurants
                let lower = ctx.response.lowercased()
                let hasRestaurant = lower.contains("ramen") || lower.contains("restaurant") ||
                                   lower.contains("sf") || lower.contains("san francisco")
                if !hasRestaurant {
                    return (false, "Should mention specific ramen places")
                }
                return (true, "OK")
            },

            Eval(name: "Reddit: API Recommendations", question: "What's the best auth library for Node.js?") { ctx in
                // Should use reddit_search for API/library recommendations
                if ctx.redditSearchCalls.isEmpty {
                    return (false, "Should use reddit_search for library recommendations")
                }
                // Response should mention specific libraries
                let lower = ctx.response.lowercased()
                let hasLibrary = lower.contains("passport") || lower.contains("auth") ||
                                lower.contains("jwt") || lower.contains("oauth") ||
                                lower.contains("library") || lower.contains("node")
                if !hasLibrary {
                    return (false, "Should mention specific auth libraries")
                }
                return (true, "OK")
            },

            Eval(name: "Reddit: Not Used for Docs", question: "How do I use useEffect in React?") { ctx in
                // Technical docs should use web_search, not Reddit
                if !ctx.redditSearchCalls.isEmpty {
                    return (false, "Should not use reddit_search for technical documentation")
                }
                // Response should explain useEffect
                let lower = ctx.response.lowercased()
                if !lower.contains("useeffect") && !lower.contains("effect") {
                    return (false, "Should explain useEffect")
                }
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
