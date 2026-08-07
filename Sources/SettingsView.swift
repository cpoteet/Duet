import SwiftUI

struct SettingsView: View {
    @AppStorage(AppPreferenceKey.startupDestination) private var startupDestination = StartupDestination.askEveryTime
    @AppStorage(AppPreferenceKey.keepProvidersLoaded) private var keepProvidersLoaded = false
    @AppStorage(AppPreferenceKey.responseCompletionNotifications) private var notifyOnResponseCompletion = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Open Duet to", selection: $startupDestination) {
                ForEach(StartupDestination.allCases) { destination in
                    Text(destination.title).tag(destination)
                }
            }
            .pickerStyle(.menu)

            Text("Choose what appears the next time Duet launches. Last Used remembers ChatGPT, Claude, or Both.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Keep both providers loaded", isOn: $keepProvidersLoaded)
                .toggleStyle(.switch)
                .padding(.top, 12)

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
