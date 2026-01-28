import SwiftUI
import MarkdownUI

/// A view that renders markdown text with LaTeX math support.
/// Uses MarkdownUI fork with native $...$ and $$...$$ math rendering.
struct MarkdownView: View {
    let text: String

    var body: some View {
        Markdown(text)
            .textSelection(.enabled)
    }
}
