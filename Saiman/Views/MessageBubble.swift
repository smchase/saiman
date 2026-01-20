import SwiftUI
import Quartz

struct MessageBubble: View {
    let message: Message

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            messageContent
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.role {
        case .user:
            userMessageContent

        case .assistant:
            MarkdownView(text: message.content)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .system:
            EmptyView()
        }
    }

    @ViewBuilder
    private var userMessageContent: some View {
        VStack(alignment: .trailing, spacing: 9) {
            // Show attachments if present
            if let attachments = message.attachments, !attachments.isEmpty {
                attachmentThumbnails(attachments)
            }

            // Show text if present
            if !message.content.isEmpty {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func attachmentThumbnails(_ attachments: [Attachment]) -> some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                MessageAttachmentThumbnail(attachment: attachment)
            }
        }
    }
}

// MARK: - Message Attachment Thumbnail

struct MessageAttachmentThumbnail: View {
    let attachment: Attachment
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        QuickLookHelper.shared.preview(url: attachment.fullPath)
                    }
            } else if !attachment.fileExists {
                // File not found placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.08))
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                        Text("Not found")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 80, height: 80)
            } else {
                // Loading placeholder
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 80, height: 80)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.5)
                    )
            }
        }
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = attachment.loadThumbnail()
            DispatchQueue.main.async {
                self.thumbnail = image
            }
        }
    }
}
