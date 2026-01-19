import Foundation
import SwiftUI
import AppKit
import UserNotifications

@MainActor
final class ChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published var inputText: String = ""
    @Published var currentConversation: Conversation?
    @Published var messages: [Message] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var pendingAttachments: [PendingAttachment] = []

    // Track pending message for cancel/restore
    private var pendingMessageText: String = ""
    private var pendingMessageId: UUID?
    private var pendingMessageAttachments: [PendingAttachment] = []

    // MARK: - Dependencies

    private let database = Database.shared
    private let agentLoop = AgentLoop()
    private let attachmentManager = AttachmentManager.shared

    // MARK: - Computed Properties

    var lastUserMessage: Message? {
        messages.last { $0.role == .user }
    }

    var canAddAttachment: Bool {
        pendingAttachments.count < AttachmentConstants.maxAttachmentsPerMessage
    }

    // MARK: - Initialization

    init() {
        // Start blank - session restoration is handled by SpotlightPanelController
    }

    // MARK: - Conversation Management

    func loadMostRecentConversation() {
        if let conversation = database.getMostRecentConversation(),
           !conversation.isStale {
            currentConversation = conversation
            messages = database.getMessages(conversationId: conversation.id)
        } else {
            startNewConversation()
        }
    }

    func startNewConversation() {
        currentConversation = nil
        messages = []
        inputText = ""
        pendingAttachments = []
        errorMessage = nil
        isLoading = false
    }

    func loadConversation(_ conversation: Conversation) {
        currentConversation = conversation
        messages = database.getMessages(conversationId: conversation.id)
        // Clear draft when navigating via menu (not session restore)
        inputText = ""
        pendingAttachments = []
        errorMessage = nil
        isLoading = false
        // Dismiss any pending notification for this conversation
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["response-\(conversation.id.uuidString)"]
        )
    }

    // MARK: - Attachment Management

    func addAttachment(_ pending: PendingAttachment) {
        guard canAddAttachment else {
            errorMessage = "Maximum \(AttachmentConstants.maxAttachmentsPerMessage) images allowed"
            return
        }
        pendingAttachments.append(pending)
    }

    func addAttachments(_ newAttachments: [PendingAttachment]) {
        let remaining = AttachmentConstants.maxAttachmentsPerMessage - pendingAttachments.count
        let toAdd = Array(newAttachments.prefix(remaining))
        pendingAttachments.append(contentsOf: toAdd)

        if newAttachments.count > remaining {
            errorMessage = "Maximum \(AttachmentConstants.maxAttachmentsPerMessage) images allowed"
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func handlePaste(from pasteboard: NSPasteboard) {
        let newAttachments = attachmentManager.loadFromPasteboard(pasteboard)
        if !newAttachments.isEmpty {
            addAttachments(newAttachments)
        }
    }

    // MARK: - Message Handling

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Allow sending with just attachments (no text required if there are images)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        guard !isLoading else { return }

        // Store for potential cancel/restore
        pendingMessageText = text
        pendingMessageAttachments = pendingAttachments
        inputText = ""
        pendingAttachments = []
        errorMessage = nil
        isLoading = true

        // Create conversation in memory if needed (not persisted yet)
        if currentConversation == nil {
            currentConversation = Conversation()
        }

        guard let conversation = currentConversation else { return }

        // Save attachments to disk and get Attachment objects
        var savedAttachments: [Attachment] = []
        for pending in pendingMessageAttachments {
            if let saved = attachmentManager.save(pending: pending, conversationId: conversation.id) {
                savedAttachments.append(saved)
            }
        }

        // Create user message
        let userMessage = Message(
            conversationId: conversation.id,
            role: .user,
            content: text,
            attachments: savedAttachments.isEmpty ? nil : savedAttachments
        )
        pendingMessageId = userMessage.id
        messages.append(userMessage)

        // Save conversation and user message immediately so they persist if popup is closed
        if database.getConversation(id: conversation.id) == nil {
            database.createConversation(conversation)
        }
        database.createMessage(userMessage)

        // Run agent
        agentLoop.run(messages: messages) { [weak self] responseText, toolCalls in
            guard let self = self else { return }

            // Create and save assistant message to database (always, regardless of current conversation)
            // Note: We don't save toolCalls - they're transient to this turn and not displayed.
            // The model can re-invoke tools if needed when continuing the conversation.
            let assistantMessage = Message(
                conversationId: conversation.id,
                role: .assistant,
                content: responseText
            )
            self.database.createMessage(assistantMessage)

            // Update conversation timestamp in database (always)
            var updatedConversation = conversation
            updatedConversation.updatedAt = Date()
            self.database.updateConversation(updatedConversation)

            // Check if we're still viewing the same conversation
            let isStillCurrentConversation = self.currentConversation?.id == conversation.id

            // Only update UI state if still in the same conversation
            if isStillCurrentConversation {
                self.messages.append(assistantMessage)
                self.currentConversation = updatedConversation
                self.isLoading = false
                self.pendingMessageText = ""
                self.pendingMessageId = nil
                self.pendingMessageAttachments = []
            }

            // Update title after each exchange (DB always, UI only if still current)
            Task {
                if let title = await self.agentLoop.generateTitle(for: self.database.getMessages(conversationId: conversation.id)) {
                    var conv = updatedConversation
                    conv.title = title
                    self.database.updateConversation(conv)
                    if self.currentConversation?.id == conversation.id {
                        self.currentConversation = conv
                    }
                }
            }

            // Notify user if this conversation is not visible (panel hidden or different conversation open)
            let conversationNotVisible = !SpotlightPanelController.shared.isVisible || !isStillCurrentConversation
            if conversationNotVisible {
                // Clean up markdown for notification preview
                let cleanSummary = responseText
                    .replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
                    .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
                    .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                NotificationManager.shared.notifyResponseReady(summary: cleanSummary, conversationId: conversation.id)
            }
        }
    }

    func cancelRequest() {
        agentLoop.cancel()
        isLoading = false

        // Restore the user's message text and attachments for editing
        inputText = pendingMessageText

        // Restore attachments - but we need to recreate PendingAttachments
        // from the saved files if they were already saved
        if let messageId = pendingMessageId,
           let message = messages.first(where: { $0.id == messageId }),
           let attachments = message.attachments {
            // Reload as pending attachments for editing
            pendingAttachments = attachments.compactMap { attachment in
                guard let data = attachment.loadImageData(),
                      let image = NSImage(data: data) else { return nil }
                return PendingAttachment(id: attachment.id, image: image, filename: attachment.filename)
            }

            // Delete the saved files since we're canceling
            for attachment in attachments {
                attachmentManager.delete(attachment: attachment)
            }
        } else {
            // Restore from in-memory pending attachments
            pendingAttachments = pendingMessageAttachments
        }

        // Remove the pending user message from UI and database
        if let messageId = pendingMessageId {
            messages.removeAll { $0.id == messageId }
            database.deleteMessage(id: messageId)
        }

        // If this was a new conversation with no completed messages, delete it
        if messages.isEmpty, let conversation = currentConversation {
            database.deleteConversation(id: conversation.id)
            currentConversation = nil
        }

        pendingMessageText = ""
        pendingMessageId = nil
        pendingMessageAttachments = []
    }

    // MARK: - Search

    func searchConversations(query: String) -> [Conversation] {
        if query.isEmpty {
            return database.getAllConversations()
        }
        return database.searchConversations(query: query)
    }

    func getAllConversations() -> [Conversation] {
        database.getAllConversations()
    }

    func deleteConversation(_ conversation: Conversation) {
        // Delete attachment files too
        attachmentManager.deleteAll(for: conversation.id)

        database.deleteConversation(id: conversation.id)
        if currentConversation?.id == conversation.id {
            startNewConversation()
        }
    }
}
