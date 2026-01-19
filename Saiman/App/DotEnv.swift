import Foundation

/// Loads environment variables from ~/.saiman/.env
enum DotEnv {
    static let configDirectory = NSHomeDirectory() + "/.saiman"
    static let envFilePath = configDirectory + "/.env"

    /// Load environment variables from ~/.saiman/.env
    static func load() {
        guard FileManager.default.fileExists(atPath: envFilePath) else {
            print("[DotEnv] No .env file at \(envFilePath)")
            return
        }

        guard let contents = try? String(contentsOfFile: envFilePath, encoding: .utf8) else {
            print("[DotEnv] Failed to read \(envFilePath)")
            return
        }

        var loadedCount = 0
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Parse KEY=VALUE
            guard let equalIndex = trimmed.firstIndex(of: "=") else {
                continue
            }

            let key = String(trimmed[..<equalIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: equalIndex)...]).trimmingCharacters(in: .whitespaces)

            // Remove surrounding quotes if present
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            // Only set if not already set (don't override existing env vars)
            if ProcessInfo.processInfo.environment[key] == nil && !value.isEmpty {
                setenv(key, value, 1)
                loadedCount += 1
            }
        }

        print("[DotEnv] Loaded \(loadedCount) variables from \(envFilePath)")
    }
}
