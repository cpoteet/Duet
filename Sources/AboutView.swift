import AppKit
import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

            Text("Duet")
                .font(.title2.weight(.semibold))

            Text("v\(version)")
                .foregroundStyle(.secondary)

            Link("View on GitHub", destination: URL(string: "https://github.com/cpoteet/Duet")!)
        }
        .multilineTextAlignment(.center)
        .frame(width: 260, height: 220)
        .padding(24)
    }
}
