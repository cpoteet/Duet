import SwiftUI

struct SettingsView: View {
    @AppStorage(AppPreferenceKey.keepProvidersLoaded) private var keepProvidersLoaded = false
    @AppStorage(AppPreferenceKey.responseCompletionNotifications) private var notifyOnResponseCompletion = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Keep both providers loaded", isOn: $keepProvidersLoaded)
                .toggleStyle(.switch)

            Text("Uses more memory for faster switching between ChatGPT and Claude.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Notify when responses finish", isOn: $notifyOnResponseCompletion)
                .toggleStyle(.switch)
                .padding(.top, 12)
                .onChange(of: notifyOnResponseCompletion) { _, enabled in
                    guard enabled else { return }
                    Task { _ = await DuetNotificationManager.shared.requestPermission() }
                }

            Text("Shows a notification when ChatGPT or Claude completes a response while you are working elsewhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 440)
    }
}
