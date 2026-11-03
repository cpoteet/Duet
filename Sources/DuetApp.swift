import Foundation
import SwiftUI

@main
struct DuetApp: App {
    @StateObject private var appState = AppState(
        startupDestination: StartupDestination.stored(in: .standard),
        userDefaults: .standard
    )
    @NSApplicationDelegateAdaptor(DuetApplicationDelegate.self) private var applicationDelegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.equalizePaneWidths) private var equalizePaneWidths

    var body: some Scene {
        WindowGroup("Duet", id: "workspace") {
            ContentView(appState: appState)
                .onAppear {
                    applicationDelegate.configureQuickPrompt(with: appState) {
                        openWindow(id: "workspace")
                    }
                    let applicationDelegate = applicationDelegate
                    let appState = appState
                    DuetNotificationManager.shared.configure { service in
                        if !appState.isSplitView {
                            appState.openWorkspace(for: .service(service))
                        }
                        applicationDelegate.revealWorkspace()
                    }
                }
        }
        .windowResizability(.contentMinSize)

        Window("About Duet", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    applicationDelegate.revealWorkspace()
                    appState.startNewConversation()
                }
                .keyboardShortcut("n")
                .disabled(!appState.canStartNewConversation)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Duet") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(before: .sidebar) {
                workspaceToggle("ChatGPT", target: .service(.chatGPT), key: "1")
                workspaceToggle("Claude", target: .service(.claude), key: "2")
                workspaceToggle("Both", target: .both, key: "3")
                Divider()
                Button("Equal Widths") {
                    equalizePaneWidths?()
                }
                .disabled(equalizePaneWidths == nil)
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

        Settings {
            SettingsView()
        }
    }

    private func workspaceToggle(_ title: String, target: PromptTarget, key: KeyEquivalent) -> some View {
        Toggle(title, isOn: Binding(
            get: { appState.isShowingWorkspace(for: target) },
            set: { _ in appState.openWorkspace(for: target) }
        ))
        .keyboardShortcut(key)
        .disabled(appState.hasActiveOperations)
    }
}
