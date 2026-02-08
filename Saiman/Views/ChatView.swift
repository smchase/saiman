import SwiftUI
import Quartz

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Messages (when there are any)
            if !viewModel.messages.isEmpty || viewModel.isLoading {
                messagesView
                Divider()
            }

            // Input area with attachments
            inputArea
        }
        .background(Color.clear)
        .onAppear {
            isInputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isInputFocused = true
        }
        .onChange(of: viewModel.currentConversation?.id) { _, _ in
            isInputFocused = true
        }
    }

    // MARK: - Messages View

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if viewModel.isLoading {
                        loadingIndicator
                    }

                    // Bottom anchor (also serves as bottom padding)
                    Color.clear
                        .frame(height: 9)
                        .id("bottom")
                }
                .padding(.top, 9)
            }
            .onChange(of: viewModel.messages.count) { oldCount, newCount in
                if newCount > oldCount {
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: viewModel.isLoading) { _, isLoading in
                if isLoading {
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: viewModel.currentConversation?.id) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onAppear {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var loadingIndicator: some View {
        HStack(alignment: .center, spacing: 6) {
            ProgressView()
                .controlSize(.small)
            if let statusText = viewModel.agentStatusText {
                Text(statusText)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(minHeight: 17)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 0) {
            // Attachment preview strip
            if !viewModel.pendingAttachments.isEmpty {
                attachmentPreview
            }

            // Input row
            TextField("Ask anything", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .onKeyPress(.return) {
                    if NSEvent.modifierFlags.contains(.shift) {
                        // Shift+Enter: insert newline at cursor position
                        if let window = NSApp.keyWindow,
                           let textView = window.firstResponder as? NSTextView {
                            textView.insertText("\n", replacementRange: textView.selectedRange())
                        }
                        return .handled
                    } else {
                        // Enter: send message
                        viewModel.sendMessage()
                        isInputFocused = true
                        return .handled
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
        }
    }

    // MARK: - Attachment Preview

    private var attachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.pendingAttachments) { attachment in
                    AttachmentThumbnail(
                        attachment: attachment,
                        onRemove: {
                            viewModel.removeAttachment(attachment.id)
                        }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12) // Room for X button above thumbnails
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6) // 6 + 12 internal = 18 from divider to image top
    }
}

// MARK: - Attachment Thumbnail

struct AttachmentThumbnail: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: attachment.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    openWithQuickLook()
                }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    private func openWithQuickLook() {
        QuickLookHelper.shared.preview(data: attachment.imageData, filename: attachment.filename)
    }
}

// MARK: - Quick Look Helper

final class QuickLookHelper: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookHelper()

    private var previewURLs: [URL] = []

    func preview(url: URL) {
        previewURLs = [url]
        QLPreviewPanel.shared()?.dataSource = self
        QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        // Keep Quick Look above our floating panel
        QLPreviewPanel.shared()?.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)) + 1)
    }

    func preview(data: Data, filename: String) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: tempURL)
        preview(url: tempURL)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs[index] as NSURL
    }
}
