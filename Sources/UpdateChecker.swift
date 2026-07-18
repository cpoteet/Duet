import Foundation

struct UpdateInfo: Equatable, Sendable {
    let version: String
    let releaseURL: URL
}

enum UpdateChecker {
    private static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/cpoteet/Duet/releases/latest"
    )!
    private static let latestReleasePage = URL(
        string: "https://github.com/cpoteet/Duet/releases/latest"
    )!
    private static let dismissedVersionKey = "DuetUpdateCheckerDismissedVersion"

    static func check() async throws -> UpdateInfo? {
        struct ReleasePayload: Decodable {
            let tagName: String

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
            }
        }

        guard let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            return nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Duet Update Checker", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
        guard let remoteVersion = normalizedVersion(payload.tagName) else {
            throw URLError(.cannotParseResponse)
        }

        let dismissedVersion = UserDefaults.standard.string(forKey: dismissedVersionKey)
        guard isNewer(remote: remoteVersion, local: currentVersion),
              remoteVersion != dismissedVersion else {
            return nil
        }

        return UpdateInfo(version: remoteVersion, releaseURL: latestReleasePage)
    }

    static func dismiss(_ version: String) {
        UserDefaults.standard.set(version, forKey: dismissedVersionKey)
    }

    static func isNewer(remote: String, local: String) -> Bool {
        guard let remoteComponents = versionComponents(remote),
              let localComponents = versionComponents(local) else {
            return false
        }

        for index in 0..<max(remoteComponents.count, localComponents.count) {
            let remoteValue = index < remoteComponents.count ? remoteComponents[index] : 0
            let localValue = index < localComponents.count ? localComponents[index] : 0
            if remoteValue > localValue { return true }
            if remoteValue < localValue { return false }
        }
        return false
    }

    static func normalizedVersion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix: Substring
        if trimmed.first?.lowercased() == "v" {
            withoutPrefix = trimmed.dropFirst()
        } else {
            withoutPrefix = Substring(trimmed)
        }

        guard versionComponents(String(withoutPrefix)) != nil else { return nil }
        return String(withoutPrefix)
    }

    private static func versionComponents(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        let components = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        return components.count == parts.count ? components : nil
    }
}
