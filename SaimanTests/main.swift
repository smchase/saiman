import Foundation

/// CLI tool for testing Saiman's production agent code.
///
/// Usage:
///   SaimanTests                     Run all tests
///   SaimanTests quick               Quick tests only (no deep research)
///   SaimanTests bedrock             Test Bedrock connectivity
///   SaimanTests exa                 Test Exa search
///   SaimanTests agent               Test agent loop
///   SaimanTests ask "your question" Ask a question using the agent

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first ?? "all"

func main() async {
    // Load .env
    DotEnv.load()

    print("==================================================")
    print("  Saiman CLI (Production Code)")
    print("==================================================")

    printConfig()

    guard Config.shared.isConfigured else {
        print("\n❌ Missing configuration:")
        for item in Config.shared.missingConfiguration {
            print("   - \(item)")
        }
        return
    }

    print("\n")

    switch mode {
    case "bedrock":
        await testBedrock()
    case "exa":
        await testExa()
    case "agent":
        await testAgent()
    case "eval", "evals":
        let runner = EvalRunner()
        await runner.runAllEvals()
    case "ask":
        let question = args.dropFirst().joined(separator: " ")
        if question.isEmpty {
            print("Usage: SaimanTests ask \"your question\"")
        } else {
            await askQuestion(question)
        }
    case "quick":
        await testBedrock()
        await testExa()
    case "all":
        await testBedrock()
        await testExa()
        await testAgent()
    case "help", "-h", "--help":
        printUsage()
    default:
        // Treat unknown args as a question
        let question = args.joined(separator: " ")
        await askQuestion(question)
    }

    print("\n==================================================")
}

func printUsage() {
    print("""
    Usage: SaimanTests [command] [args]

    Commands:
      (none)              Run all tests
      quick               Quick tests only
      bedrock             Test Bedrock connectivity
      exa                 Test Exa search
      agent               Test agent loop
      eval                Run evaluation suite
      ask "question"      Ask a question using the agent
      help                Show this help

    Or just pass a question directly:
      SaimanTests What is the weather in SF?
    """)
}

func printConfig() {
    let config = Config.shared
    print("\n📋 Configuration:")
    print("   AWS Region: \(config.awsRegion)")
    print("   AWS Key: \(config.awsAccessKeyId.isEmpty ? "❌ Missing" : "✓ \(config.awsAccessKeyId.prefix(8))...")")
    print("   Exa Key: \(config.exaApiKey.isEmpty ? "❌ Missing" : "✓ \(config.exaApiKey.prefix(8))...")")
    print("   Model: \(config.bedrockModelId)")
}

// MARK: - Tests

func testBedrock() async {
    print("📝 Testing Bedrock...")

    let client = BedrockClient()
    let message = Message(
        conversationId: UUID(),
        role: .user,
        content: "What is 2 + 2? Reply in one word."
    )

    do {
        let response = try await client.sendMessage(messages: [message], tools: [])
        print("   ✓ Response: \(response.text)")
    } catch {
        print("   ❌ Error: \(error.localizedDescription)")
    }
}

func testExa() async {
    print("\n📝 Testing Exa Search...")

    let client = ExaClient()

    // Quick search
    do {
        let results = try await client.search(query: "current weather", depth: .quick)
        print("   ✓ Quick: \(results.count) results")
    } catch {
        print("   ❌ Quick: \(error.localizedDescription)")
    }

    // Deep search
    do {
        let results = try await client.search(query: "Swift concurrency patterns", depth: .deep)
        print("   ✓ Deep: \(results.count) results")
    } catch {
        print("   ❌ Deep: \(error.localizedDescription)")
    }
}

func testAgent() async {
    print("\n📝 Testing Agent Loop...")
    await askQuestion("What are the top 3 programming languages in 2024? Be brief and cite sources.")
}

@MainActor
func askQuestion(_ question: String) async {
    print("   Question: \(question)\n")

    let agentLoop = AgentLoop()
    let conversationId = UUID()

    let userMessage = Message(
        conversationId: conversationId,
        role: .user,
        content: question
    )

    await withCheckedContinuation { continuation in
        agentLoop.run(messages: [userMessage]) { response, toolCalls in
            if !toolCalls.isEmpty {
                print("   🔧 Tool calls: \(toolCalls.count)")
                for call in toolCalls {
                    let args = call.arguments.prefix(60)
                    print("      - \(call.name): \(args)...")
                }
                print("")
            }

            print("   📝 Response:")
            print("   " + response.replacingOccurrences(of: "\n", with: "\n   "))
            continuation.resume()
        }
    }
}

// MARK: - Entry Point

// Use RunLoop to support MainActor dispatches
Task { @MainActor in
    await main()
    exit(0)
}
RunLoop.main.run()
