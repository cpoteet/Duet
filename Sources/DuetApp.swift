import SwiftUI

@main
struct DuetApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(DuetApplicationDelegate.self) private var applicationDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Duet", id: "workspace") {
            ContentView(appState: appState)
                .onAppear {
                    applicationDelegate.configureQuickPrompt(with: appState) {
                        openWindow(id: "workspace")
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        Window("About Duet", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About Duet") {
                    openWindow(id: "about")
                }
            }
            CommandMenu("Session") {
                Button("Reset ChatGPT Website Data", role: .destructive) {
                    Task { await appState.clearWebsiteData(for: .chatGPT) }
                }
                .disabled(appState.isBusy(.chatGPT))
                Button("Reset Claude Website Data", role: .destructive) {
                    Task { await appState.clearWebsiteData(for: .claude) }
                }
                .disabled(appState.isBusy(.claude))
            }
            CommandMenu("Tools") {
                Button("Quick Prompt") {
                    applicationDelegate.showQuickPrompt()
                }
            }
        }
    }
}
