import SwiftUI

private let conversationRowHeight: CGFloat = 48
private let visibleConversationRows: Int = 5

struct MenuBarView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var searchText: String = ""
    @State private var conversations: [Conversation]
    @FocusState private var isSearchFocused: Bool

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        _conversations = State(initialValue: viewModel.searchConversations(query: ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))

                TextField("Search conversations...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
                    .onChange(of: searchText) { _, newValue in
                        refreshConversations(query: newValue)
                    }

            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Conversations list
            Group {
                if conversations.isEmpty {
                    emptyState
                } else {
                    conversationsList
                }
            }
            .frame(height: CGFloat(visibleConversationRows) * conversationRowHeight)

            Divider()

            // Footer
            footerActions
        }
        .frame(width: 280)
        .onReceive(NotificationCenter.default.publisher(for: .menuBarPopoverWillShow)) { _ in
            searchText = ""
            refreshConversations(query: "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(.secondary)

            Text(searchText.isEmpty ? "No conversations yet" : "No results found")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Conversations List

    private var conversationsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(conversations) { conversation in
                    ConversationRow(
                        conversation: conversation,
                        onSelect: {
                            viewModel.loadConversation(conversation)
                            SpotlightPanelController.shared.showPanel()
                        },
                        onDelete: {
                            viewModel.deleteConversation(conversation)
                            refreshConversations(query: searchText)
                        }
                    )
                }
            }
        }
        .clipped()
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack {
            FooterButton(
                icon: "plus",
                action: { SpotlightPanelController.shared.startNewConversation() }
            )

            Spacer()

            TokenDisplay()

            Spacer()

            FooterButton(
                icon: "power",
                action: { NSApplication.shared.terminate(nil) }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func refreshConversations(query: String = "") {
        conversations = viewModel.searchConversations(query: query)
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isTrashHovered = false

    private var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: conversation.updatedAt, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(timeAgo)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(isTrashHovered ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isTrashHovered = hovering
                }
                .help("Delete conversation")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: conversationRowHeight)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onSelect()
        }
    }
}

// MARK: - Footer Button

struct FooterButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
    }
}

// MARK: - Token Display

struct TokenDisplay: View {
    @ObservedObject private var tracker = TokenTracker.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up")
                .font(.system(size: 9))
            Text(TokenTracker.formatCount(tracker.totalInputTokens))
                .font(.system(size: 11, design: .monospaced))

            Text("/")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Image(systemName: "arrow.down")
                .font(.system(size: 9))
            Text(TokenTracker.formatCount(tracker.totalOutputTokens))
                .font(.system(size: 11, design: .monospaced))
        }
        .foregroundColor(.secondary)
    }
}
