import Foundation

/// Represents a segment of content for rendering
enum ContentSegment: Equatable {
    case markdown(String)      // Render with MarkdownUI
    case textWithMath(String)  // Text with inline math - render with LaTeXSwiftUI
    case mathBlock(String)     // Block math ($$...$$) - render centered with LaTeXSwiftUI
}

/// Parses text containing mixed markdown and LaTeX content into segments.
/// Uses paragraph-level routing to maximize compatibility.
struct ContentParser {

    /// Parses text into an array of ContentSegment
    static func parse(_ text: String) -> [ContentSegment] {
        var segments: [ContentSegment] = []

        // Step 1: Split by block math ($$...$$) first
        let parts = splitByBlockMath(text)

        for part in parts {
            if part.isBlockMath {
                // Block math - extract expression without delimiters
                let expr = String(part.content.dropFirst(2).dropLast(2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !expr.isEmpty {
                    segments.append(.mathBlock(expr))
                }
            } else {
                // Step 2: Split non-math content by paragraphs (double newline)
                let paragraphs = splitIntoParagraphs(part.content)

                for paragraph in paragraphs {
                    let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    // Step 3: Route based on paragraph type
                    let segment = routeParagraph(trimmed)
                    segments.append(segment)
                }
            }
        }

        if segments.isEmpty {
            return [.markdown(text)]
        }

        return segments
    }

    /// Routes a paragraph to the appropriate renderer based on its content
    private static func routeParagraph(_ paragraph: String) -> ContentSegment {
        // Check if it's a markdown block element (should go to MarkdownUI)
        if isMarkdownBlockElement(paragraph) {
            return .markdown(paragraph)
        }

        // Check if it contains inline math
        if containsInlineMath(paragraph) {
            return .textWithMath(paragraph)
        }

        // Default to markdown
        return .markdown(paragraph)
    }

    /// Checks if a paragraph is a markdown block element that MarkdownUI should handle
    private static func isMarkdownBlockElement(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // Header (# ## ### etc.)
        if trimmed.hasPrefix("#") {
            return true
        }

        // Code block (``` or ~~~)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            return true
        }

        // Table (starts with |)
        if trimmed.hasPrefix("|") {
            return true
        }

        // Unordered list (- or * or +)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return true
        }

        // Ordered list (1. 2. etc.)
        if let firstChar = trimmed.first, firstChar.isNumber {
            let pattern = #"^\d+\.\s"#
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }

        // Blockquote
        if trimmed.hasPrefix(">") {
            return true
        }

        // Horizontal rule
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            return true
        }

        return false
    }

    /// Checks if text contains inline math ($...$) but not block math
    private static func containsInlineMath(_ text: String) -> Bool {
        // Look for $...$ patterns (single $, not $$)
        var i = 0
        let chars = Array(text)

        while i < chars.count {
            if chars[i] == "$" {
                // Skip if it's $$
                if i + 1 < chars.count && chars[i + 1] == "$" {
                    i += 2
                    continue
                }

                // Look for closing $
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "$" {
                        // Skip if it's $$ (block math delimiter)
                        if j + 1 < chars.count && chars[j + 1] == "$" {
                            j += 2
                            continue
                        }
                        // Skip if closing $ is followed by a digit (likely currency like "$5 to $10")
                        if j + 1 < chars.count && chars[j + 1].isNumber {
                            j += 1
                            continue
                        }
                        // Found valid closing $ - this is inline math
                        return true
                    }
                    j += 1
                }
            }
            i += 1
        }

        return false
    }

    /// Splits text into paragraphs by double newlines, preserving code blocks
    private static func splitIntoParagraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        var inCodeBlock = false

        let lines = text.components(separatedBy: "\n")

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Track code block state
            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                inCodeBlock = !inCodeBlock
            }

            // Check if this is a blank line (paragraph separator)
            let isBlankLine = trimmedLine.isEmpty

            if isBlankLine && !inCodeBlock {
                // End of paragraph
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
            } else {
                // Add to current paragraph
                if !current.isEmpty {
                    current += "\n"
                }
                current += line
            }
        }

        // Don't forget the last paragraph
        if !current.isEmpty {
            paragraphs.append(current)
        }

        return paragraphs
    }

    // MARK: - Block Math Splitting

    private struct TextPart {
        let content: String
        let isBlockMath: Bool
    }

    /// Splits text by block math ($$...$$), preserving the delimiters in block math parts
    private static func splitByBlockMath(_ text: String) -> [TextPart] {
        var parts: [TextPart] = []
        var currentIndex = text.startIndex
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            // Look for $$
            if i + 1 < chars.count && chars[i] == "$" && chars[i + 1] == "$" {
                // Add text before this block math
                let beforeIndex = text.index(text.startIndex, offsetBy: i)
                if currentIndex < beforeIndex {
                    let before = String(text[currentIndex..<beforeIndex])
                    parts.append(TextPart(content: before, isBlockMath: false))
                }

                // Find closing $$
                var j = i + 2
                var found = false
                while j + 1 < chars.count {
                    if chars[j] == "$" && chars[j + 1] == "$" {
                        // Found closing $$
                        let startIndex = text.index(text.startIndex, offsetBy: i)
                        let endIndex = text.index(text.startIndex, offsetBy: j + 2)
                        let blockMath = String(text[startIndex..<endIndex])
                        parts.append(TextPart(content: blockMath, isBlockMath: true))
                        currentIndex = endIndex
                        i = j + 2
                        found = true
                        break
                    }
                    j += 1
                }

                if !found {
                    // No closing $$ found, treat as regular text
                    i += 1
                }
                continue
            }
            i += 1
        }

        // Add remaining text
        if currentIndex < text.endIndex {
            let remaining = String(text[currentIndex..<text.endIndex])
            parts.append(TextPart(content: remaining, isBlockMath: false))
        }

        return parts
    }
}
