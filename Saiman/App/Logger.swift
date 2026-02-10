import Foundation

/// Simple persistent logger that writes to ~/.saiman/logs/
final class Logger {
    static let shared = Logger()

    private let logDirectory: URL
    private let logFile: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.saiman.logger")

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        logDirectory = home.appendingPathComponent(".saiman/logs")

        // Create log directory if needed
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        // Log file named by date
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let fileName = "saiman-\(dayFormatter.string(from: Date())).log"
        logFile = logDirectory.appendingPathComponent(fileName)

        // Timestamp formatter
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"

        log("=== Saiman started ===")
    }

    func log(_ message: String, level: String = "INFO") {
        queue.async {
            let timestamp = self.dateFormatter.string(from: Date())
            let entry = "[\(timestamp)] [\(level)] \(message)\n"

            if let data = entry.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.logFile.path) {
                    if let handle = try? FileHandle(forWritingTo: self.logFile) {
                        defer { handle.closeFile() }
                        handle.seekToEndOfFile()
                        handle.write(data)
                    }
                } else {
                    try? data.write(to: self.logFile)
                }
            }

            // Also print to console in debug
            #if DEBUG
            print(entry, terminator: "")
            #endif
        }
    }

    func debug(_ message: String) {
        log(message, level: "DEBUG")
    }

    func info(_ message: String) {
        log(message, level: "INFO")
    }

    func error(_ message: String) {
        log(message, level: "ERROR")
    }

    func logRequest(_ messages: [[String: Any]]) {
        log("API Request - \(messages.count) messages", level: "DEBUG")
        for (i, msg) in messages.enumerated() {
            let role = msg["role"] as? String ?? "unknown"
            let content = msg["content"]
            var contentDesc = ""
            if let str = content as? String {
                contentDesc = "text(\(str.prefix(50))...)"
            } else if let arr = content as? [[String: Any]] {
                let types = arr.compactMap { $0["type"] as? String }
                contentDesc = "[\(types.joined(separator: ", "))]"
            }
            log("  [\(i)] role=\(role) content=\(contentDesc)", level: "DEBUG")
        }
    }

    func logResponse(_ response: String, toolCalls: Int, thinkingBlocks: Int = 0) {
        var msg = "API Response - \(response.count) chars, \(toolCalls) tool calls"
        if thinkingBlocks > 0 {
            msg += ", \(thinkingBlocks) thinking blocks"
        }
        log(msg, level: "DEBUG")
    }

}
