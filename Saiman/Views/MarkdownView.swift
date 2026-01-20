import SwiftUI
import MarkdownUI
import LaTeXSwiftUI

/// A view that renders markdown text with LaTeX math support.
struct MarkdownView: View {
    let text: String

    var body: some View {
        let segments = ContentParser.parse(text)

        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let content):
                    // Pure markdown - headers, tables, code blocks, lists
                    Markdown(content)
                        .textSelection(.enabled)

                case .textWithMath(let content):
                    // Text with inline math - LaTeXSwiftUI handles the flow
                    LaTeX(content)
                        .textSelection(.enabled)

                case .mathBlock(let expr):
                    // Block math - centered
                    LaTeX("$$\(expr)$$")
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
