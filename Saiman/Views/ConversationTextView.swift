import SwiftUI
import AppKit

/// A unified text view for the entire conversation using TextKit 2.
/// All messages are rendered in a single NSTextView, enabling unified text selection.
struct ConversationTextView: NSViewRepresentable {
    let messages: [Message]

    func makeNSView(context: Context) -> NSScrollView {
        // Create text content storage (TextKit 2)
        let textContentStorage = NSTextContentStorage()

        // Create text layout manager
        let textLayoutManager = NSTextLayoutManager()
        textLayoutManager.delegate = context.coordinator
        textContentStorage.addTextLayoutManager(textLayoutManager)

        // Create text container
        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textLayoutManager.textContainer = textContainer

        // Create text view
        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.usesAdaptiveColorMappingForDarkAppearance = true

        // Typography settings
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        // Store references in coordinator
        context.coordinator.textView = textView
        context.coordinator.textContentStorage = textContentStorage

        // Create scroll view
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        // Configure text view to resize with scroll view
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 18, height: 18)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Build attributed string from messages
        let attributedString = buildAttributedString(from: messages)

        // Update text storage
        if let textContentStorage = context.coordinator.textContentStorage {
            textContentStorage.textStorage?.setAttributedString(attributedString)
        }

        // Scroll to bottom if needed
        DispatchQueue.main.async {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Build Attributed String

    private func buildAttributedString(from messages: [Message]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let baseFont = NSFont.systemFont(ofSize: 13)
        let baseParagraphStyle = NSMutableParagraphStyle()
        baseParagraphStyle.lineSpacing = 4
        baseParagraphStyle.paragraphSpacing = 18

        for (index, message) in messages.enumerated() {
            guard message.role != .system else { continue }

            let isUser = message.role == .user

            // Create paragraph style
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 4
            paragraphStyle.paragraphSpacing = 18

            if isUser {
                // Right-align user messages
                paragraphStyle.alignment = .right
            } else {
                paragraphStyle.alignment = .left
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]

            if isUser {
                // Mark as user message for bubble rendering
                attributes[.isUserMessage] = true
            }

            // Convert content to attributed string
            let content: NSAttributedString
            if isUser {
                content = NSAttributedString(string: message.content, attributes: attributes)
            } else {
                // For assistant messages, parse markdown
                content = parseMarkdown(message.content, baseAttributes: attributes)
            }

            result.append(content)

            // Add newline between messages (except for last)
            if index < messages.count - 1 {
                result.append(NSAttributedString(string: "\n\n", attributes: [
                    .font: baseFont,
                    .paragraphStyle: baseParagraphStyle
                ]))
            }
        }

        return result
    }

    // MARK: - Simple Markdown Parser

    private func parseMarkdown(_ text: String, baseAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)

        // Simple bold parsing: **text**
        let boldPattern = "\\*\\*(.+?)\\*\\*"
        if let regex = try? NSRegularExpression(pattern: boldPattern, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)

            // Process in reverse to maintain ranges
            for match in matches.reversed() {
                if let matchRange = Range(match.range, in: text),
                   let groupRange = Range(match.range(at: 1), in: text) {
                    let boldText = String(text[groupRange])
                    var boldAttributes = baseAttributes
                    boldAttributes[.font] = NSFont.boldSystemFont(ofSize: 13)
                    let replacement = NSAttributedString(string: boldText, attributes: boldAttributes)
                    result.replaceCharacters(in: NSRange(matchRange, in: text), with: replacement)
                }
            }
        }

        // Simple italic parsing: *text* (but not **)
        let italicPattern = "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)"
        if let regex = try? NSRegularExpression(pattern: italicPattern, options: []) {
            let currentText = result.string
            let range = NSRange(currentText.startIndex..., in: currentText)
            let matches = regex.matches(in: currentText, options: [], range: range)

            for match in matches.reversed() {
                if let matchRange = Range(match.range, in: currentText),
                   let groupRange = Range(match.range(at: 1), in: currentText) {
                    let italicText = String(currentText[groupRange])
                    var italicAttributes = baseAttributes
                    italicAttributes[.font] = NSFont.systemFont(ofSize: 13).italic()
                    let replacement = NSAttributedString(string: italicText, attributes: italicAttributes)
                    result.replaceCharacters(in: NSRange(matchRange, in: currentText), with: replacement)
                }
            }
        }

        // Simple code parsing: `code`
        let codePattern = "`(.+?)`"
        if let regex = try? NSRegularExpression(pattern: codePattern, options: []) {
            let currentText = result.string
            let range = NSRange(currentText.startIndex..., in: currentText)
            let matches = regex.matches(in: currentText, options: [], range: range)

            for match in matches.reversed() {
                if let matchRange = Range(match.range, in: currentText),
                   let groupRange = Range(match.range(at: 1), in: currentText) {
                    let codeText = String(currentText[groupRange])
                    var codeAttributes = baseAttributes
                    codeAttributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                    codeAttributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08)
                    let replacement = NSAttributedString(string: codeText, attributes: codeAttributes)
                    result.replaceCharacters(in: NSRange(matchRange, in: currentText), with: replacement)
                }
            }
        }

        return result
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextLayoutManagerDelegate {
        weak var textView: NSTextView?
        var textContentStorage: NSTextContentStorage?

        func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager,
            textLayoutFragmentFor location: NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            // Check if this location has the user message attribute
            guard let textContentStorage = textContentStorage,
                  let offset = textLayoutManager.offset(from: textLayoutManager.documentRange.location, to: location) as Int?,
                  offset >= 0,
                  let textStorage = textContentStorage.textStorage,
                  offset < textStorage.length else {
                return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
            }

            let isUserMessage = textStorage.attribute(.isUserMessage, at: offset, effectiveRange: nil) as? Bool ?? false

            if isUserMessage {
                return BubbleLayoutFragment(textElement: textElement, range: textElement.elementRange)
            } else {
                return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
            }
        }
    }
}

// MARK: - Font Extension

extension NSFont {
    func italic() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
