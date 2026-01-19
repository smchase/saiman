import SwiftUI
import MarkdownUI

/// A view that renders markdown text using MarkdownUI.
struct MarkdownView: View {
    let text: String

    var body: some View {
        Markdown(text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
