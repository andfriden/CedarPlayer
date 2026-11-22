import Foundation
import SwiftUI

struct AvailableUpdate: Identifiable {
    let version: String
    let url: URL
    var id: String { version }
}

/// Checks the public GitHub Releases feed once per day and at most once per launch.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var available: AvailableUpdate?
    @Published private(set) var isChecking = false

    private var checkedThisLaunch = false
    private static let endpoint = URL(string: "https://api.github.com/repos/andfriden/CedarPlayer/releases/latest")!

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft, prerelease
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func checkAtLaunch() async {
        guard !checkedThisLaunch else { return }
        checkedThisLaunch = true
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "checkForUpdates") as? Bool ?? true else { return }
        if let last = defaults.object(forKey: "lastUpdateCheck") as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 {
            return
        }
        await check()
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CedarPlayer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
        UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease,
              let url = URL(string: release.htmlURL) else { return }

        let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isNewer(version, than: currentVersion),
              UserDefaults.standard.string(forKey: "skippedUpdateVersion") != version else { return }
        available = AvailableUpdate(version: version, url: url)
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let lhs = parts(remote)
        let rhs = parts(local)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
