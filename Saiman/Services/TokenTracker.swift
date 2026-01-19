import Foundation
import Combine

/// Tracks cumulative token usage across all API calls.
/// Persists to UserDefaults so counts survive app restarts and conversation deletions.
final class TokenTracker: ObservableObject {
    static let shared = TokenTracker()

    private let inputTokensKey = "totalInputTokens"
    private let outputTokensKey = "totalOutputTokens"

    /// Published properties for SwiftUI observation
    @Published private(set) var totalInputTokens: Int
    @Published private(set) var totalOutputTokens: Int

    private init() {
        self.totalInputTokens = UserDefaults.standard.integer(forKey: inputTokensKey)
        self.totalOutputTokens = UserDefaults.standard.integer(forKey: outputTokensKey)
    }

    /// Add token usage from an API response
    func add(usage: UsageData?) {
        guard let usage = usage else { return }
        add(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens)
    }

    /// Add token usage with explicit counts
    func add(inputTokens: Int, outputTokens: Int) {
        DispatchQueue.main.async { [self] in
            totalInputTokens += inputTokens
            totalOutputTokens += outputTokens
            // Persist to UserDefaults
            UserDefaults.standard.set(totalInputTokens, forKey: inputTokensKey)
            UserDefaults.standard.set(totalOutputTokens, forKey: outputTokensKey)
        }
    }

    /// Format token counts for display (e.g., "1.2M" or "45K")
    static func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000.0
            return String(format: "%.1fM", millions)
        } else if count >= 1_000 {
            let thousands = Double(count) / 1_000.0
            return String(format: "%.1fK", thousands)
        } else {
            return "\(count)"
        }
    }
}
