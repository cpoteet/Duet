import SwiftUI

struct SettingsView: View {
    @AppStorage(AppPreferenceKey.startupDestination) private var startupDestination = StartupDestination.askEveryTime
    @AppStorage(AppPreferenceKey.keepProvidersLoaded) private var keepProvidersLoaded = false
    @AppStorage(AppPreferenceKey.responseCompletionNotifications) private var notifyOnResponseCompletion = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text("General")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    SettingsRow(
                        title: "When Duet opens",
                        help: "Choose what Duet shows at launch. Last Used restores your most recent provider layout."
                    ) {
                        Picker("When Duet opens", selection: $startupDestination) {
                            ForEach(StartupDestination.allCases) { destination in
                                Text(destination.title).tag(destination)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    Divider()

                    SettingsRow(
                        title: "Keep both providers loaded",
                        help: "Uses more memory to make provider switching faster."
                    ) {
                        Toggle("Keep both providers loaded", isOn: $keepProvidersLoaded)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Notifications")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    SettingsRow(
                        title: "Notify when responses finish",
                        help: "Shows a notification when a response finishes while Duet is out of view."
                    ) {
                        Toggle("Notify when responses finish", isOn: $notifyOnResponseCompletion)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: notifyOnResponseCompletion) { _, enabled in
                                guard enabled else { return }
                                Task { _ = await DuetNotificationManager.shared.requestPermission() }
                            }
                    }
                }
                .padding(4)
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let help: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.medium)

                Text(help)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 320, alignment: .leading)

            Spacer(minLength: 16)

            control()
                .fixedSize()
                .frame(width: 150, alignment: .trailing)
                .padding(.top, 2)
        }
    }
}
