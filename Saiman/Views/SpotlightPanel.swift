import SwiftUI
import AppKit
import UserNotifications

/// A floating panel that behaves like Spotlight search.
/// - Appears above all windows
/// - Doesn't steal focus from other apps
/// - Dismisses when clicking outside or pressing Escape
/// - Remembers position across sessions
final class SpotlightPanel: NSPanel {
    private static let positionXKey = "SpotlightPanelPositionX"
    private static let positionYKey = "SpotlightPanelPositionY"
    private static let hasCustomPositionKey = "SpotlightPanelHasCustomPosition"

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 52),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView
        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Use hidesOnDeactivate for automatic hiding when clicking outside
        self.hidesOnDeactivate = true

        restorePosition()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        // Notify controller that panel was hidden (by us or by system)
        Task { @MainActor in
            SpotlightPanelController.shared.panelWasHidden()
        }
    }

    private func restorePosition() {
        if UserDefaults.standard.bool(forKey: Self.hasCustomPositionKey) {
            let x = UserDefaults.standard.double(forKey: Self.positionXKey)
            let topY = UserDefaults.standard.double(forKey: Self.positionYKey)
            // Convert top-left to bottom-left origin
            let originY = topY - frame.height
            setFrameOrigin(NSPoint(x: x, y: originY))
        } else {
            centerOnScreen()
        }
    }

    private func savePosition() {
        // Save top-left corner (not bottom-left origin) so position is
        // consistent regardless of window height changes
        let topLeft = NSPoint(x: frame.origin.x, y: frame.origin.y + frame.height)
        UserDefaults.standard.set(topLeft.x, forKey: Self.positionXKey)
        UserDefaults.standard.set(topLeft.y, forKey: Self.positionYKey)
        UserDefaults.standard.set(true, forKey: Self.hasCustomPositionKey)
    }

    func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelWidth: CGFloat = 680
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - 180 // Position near top of screen like Spotlight
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        savePosition()
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        orderOut(nil)
    }
}

// MARK: - SpotlightPanelController

@MainActor
final class SpotlightPanelController: ObservableObject {
    private var panel: SpotlightPanel?
    let viewModel = ChatViewModel()

    // Session snapshot for "continue where you left off" behavior
    private struct SessionSnapshot {
        let conversationId: UUID?  // nil = new conversation
        let inputText: String
        let attachments: [PendingAttachment]
        let timestamp: Date
    }
    private var sessionSnapshot: SessionSnapshot?

    // Track intended visibility state (separate from actual visibility)
    private var wantVisible = false

    static let shared = SpotlightPanelController()

    private init() {}

    func setup() {
        let hostingView = NSHostingView(rootView: SpotlightContentView(viewModel: viewModel))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel = SpotlightPanel(contentView: hostingView)

        // When app deactivates (clicking outside), hidesOnDeactivate handles hiding the panel.
        // However, if Quick Look was the key window, hidesOnDeactivate doesn't work properly.
        // In that case, we need to explicitly hide the panel.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak panelRef = panel] _ in
            // If panel is still visible, hidesOnDeactivate didn't work (QL was likely key)
            // Explicitly hide it so state stays in sync
            if panelRef?.isVisible == true {
                panelRef?.orderOut(nil)
            }
        }

        // Local key monitor for keyboard shortcuts
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel?.isVisible == true else { return event }

            // Escape - hide panel (only if our panel is key, let Quick Look handle its own Escape)
            if event.keyCode == 53 && self.panel?.isKeyWindow == true {
                self.hide()
                return nil
            }

            // Ctrl+C to cancel request
            if event.modifierFlags.contains(.control) && event.keyCode == 8 { // C key
                if self.viewModel.isLoading {
                    self.viewModel.cancelRequest()
                }
                return nil
            }

            // Cmd+N for new conversation
            if event.modifierFlags.contains(.command) && event.keyCode == 45 {
                self.viewModel.startNewConversation()
                return nil
            }

            // Cmd+W to close
            if event.modifierFlags.contains(.command) && event.keyCode == 13 {
                self.hide()
                return nil
            }

            // Cmd+V to paste images
            if event.modifierFlags.contains(.command) && event.keyCode == 9 { // V key
                let pasteboard = NSPasteboard.general
                if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) ||
                   pasteboard.types?.contains(.fileURL) == true {
                    self.viewModel.handlePaste(from: pasteboard)
                    return nil
                }
            }

            return event
        }
    }

    // MARK: - Session Snapshot Management

    /// Saves the current state as a snapshot for restoration when the panel reopens.
    private func saveSessionSnapshot() {
        sessionSnapshot = SessionSnapshot(
            conversationId: viewModel.currentConversation?.id,
            inputText: viewModel.inputText,
            attachments: viewModel.pendingAttachments,
            timestamp: Date()
        )
    }

    /// Attempts to restore the session snapshot. Returns true if successful.
    /// Fails if: no snapshot, snapshot expired (>15 min), or conversation was deleted.
    private func restoreSessionSnapshot() -> Bool {
        guard let snapshot = sessionSnapshot else { return false }

        // Check timeout (reuse stale timeout setting)
        let timeoutSeconds = Double(Config.shared.staleTimeoutMinutes * 60)
        let elapsed = Date().timeIntervalSince(snapshot.timestamp)
        guard elapsed < timeoutSeconds else { return false }

        // Restore conversation state
        if let conversationId = snapshot.conversationId {
            // Existing conversation - load from database (gets fresh messages)
            guard let conversation = Database.shared.getConversation(id: conversationId) else {
                // Conversation was deleted
                return false
            }
            viewModel.currentConversation = conversation
            viewModel.messages = Database.shared.getMessages(conversationId: conversationId)
        } else {
            // Was a new conversation (no messages yet)
            viewModel.currentConversation = nil
            viewModel.messages = []
        }

        // Restore draft
        viewModel.inputText = snapshot.inputText
        viewModel.pendingAttachments = snapshot.attachments
        viewModel.errorMessage = nil

        return true
    }

    /// Starts a blank new conversation with no draft.
    private func startBlankConversation() {
        viewModel.currentConversation = nil
        viewModel.messages = []
        viewModel.inputText = ""
        viewModel.pendingAttachments = []
        viewModel.errorMessage = nil
    }

    // MARK: - Panel Visibility

    func toggle() {
        if wantVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        wantVisible = true

        // If already visible, just bring to front
        if panel?.isVisible == true {
            panel?.show()
            dismissNotificationForCurrentConversation()
            return
        }

        // Try to restore session, otherwise start blank
        if !restoreSessionSnapshot() {
            startBlankConversation()
        }
        panel?.show()
        dismissNotificationForCurrentConversation()
    }

    func hide() {
        wantVisible = false
        saveSessionSnapshot()
        panel?.hide()
    }

    /// Called when panel is hidden (by us or by system via hidesOnDeactivate)
    func panelWasHidden() {
        saveSessionSnapshot()
        wantVisible = false
    }

    func showPanel() {
        // Just show the panel without loading anything (used by menu bar)
        wantVisible = true
        panel?.show()
        dismissNotificationForCurrentConversation()
    }

    func startNewConversation() {
        // Save current state before clearing (preserves work if user changes mind)
        saveSessionSnapshot()
        viewModel.startNewConversation()
        wantVisible = true
        panel?.show()
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private func dismissNotificationForCurrentConversation() {
        guard let conversationId = viewModel.currentConversation?.id else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["response-\(conversationId.uuidString)"]
        )
    }
}

// MARK: - Spotlight Content View

struct SpotlightContentView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ChatView(viewModel: viewModel)
        }
        .frame(width: 680)
        .frame(maxHeight: 680)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            ZStack {
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
                if colorScheme == .light {
                    Color.white.opacity(0.5)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Visual Effect View

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.layer?.cornerRadius = cornerRadius
    }
}

// MARK: - Notification Manager

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyResponseReady(summary: String, conversationId: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "Response Finished"
        // Truncate to ~100 chars for notification body
        let truncated = summary.prefix(100)
        content.body = truncated.count < summary.count ? "\(truncated)..." : String(truncated)
        content.sound = .default
        content.userInfo = ["conversationId": conversationId.uuidString]

        let request = UNNotificationRequest(
            identifier: "response-\(conversationId.uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // Handle notification tap
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let conversationIdString = userInfo["conversationId"] as? String

        Task { @MainActor in
            // Load the conversation from the notification, then show panel
            if let idString = conversationIdString,
               let conversationId = UUID(uuidString: idString),
               let conversation = Database.shared.getConversation(id: conversationId) {
                SpotlightPanelController.shared.viewModel.loadConversation(conversation)
            }
            SpotlightPanelController.shared.showPanel()
        }
        completionHandler()
    }

    // Show notification even when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
