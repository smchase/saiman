import SwiftUI

@main
struct SaimanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty scene - we use menu bar and floating panel instead
        Settings {
            EmptyView()
        }
    }
}
