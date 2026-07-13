import SwiftUI

enum AppPreferenceKey {
    static let keepProvidersLoaded = "keepProvidersLoaded"
}

struct SettingsView: View {
    @AppStorage(AppPreferenceKey.keepProvidersLoaded) private var keepProvidersLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Keep both providers loaded", isOn: $keepProvidersLoaded)
                .toggleStyle(.switch)

            Text("Uses more memory for faster switching between ChatGPT and Claude.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 440)
    }
}
