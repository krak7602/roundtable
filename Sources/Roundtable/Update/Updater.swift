import Foundation
import AppKit
import Security

/// Self-update, on top of the GitHub releases the project already publishes.
///
/// The moving parts are deliberately kept behind `UpdateSource` and `UpdateState`.
/// Sparkle is the obvious eventual home for this, and it drives the same
/// lifecycle — check, download, ready, relaunch — so swapping the implementation
/// should not reach into the view. What Sparkle *would* additionally require
/// (an appcast feed, an EdDSA key, and signing nested code inside the bundle)
/// is infrastructure this deliberately avoids for now, since the release feed
/// already exists and the app is already Developer ID signed.

/// A published build newer than the one running.
struct UpdateRelease: Equatable, Sendable {
    let version: String
    let downloadURL: URL
    let pageURL: URL
}

/// What the footer needs to know, and nothing more.
enum UpdateState: Equatable {
    case idle
    case checking
    case available(UpdateRelease)
    case downloading(Double)
    case readyToRelaunch
    case failed(String)

    var release: UpdateRelease? {
        if case .available(let r) = self { return r }
        return nil
    }
}

/// Where new versions are discovered. One implementation today; the point of the
/// protocol is that there could be another.
protocol UpdateSource: Sendable {
    func latest() async throws -> UpdateRelease?
}

/// Reads the repository's own releases. No token: the endpoint is public, and
/// the unauthenticated rate limit is 60/hour against a twice-daily check.
struct GitHubReleaseSource: UpdateSource {
    var repo = "krak7602/roundtable"
    var assetName = "Roundtable.dmg"

    func latest() async throws -> UpdateRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Roundtable", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: String }
            let tag_name: String
            let html_url: String
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease,
              let asset = payload.assets.first(where: { $0.name == assetName }),
              let download = URL(string: asset.browser_download_url),
              let page = URL(string: payload.html_url)
        else { return nil }

        return UpdateRelease(version: payload.tag_name.trimmingPrefix("v").description,
                             downloadURL: download, pageURL: page)
    }
}

@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var state: UpdateState = .idle

    /// Twice a day. Often enough that a fix reaches people the same day, rare
    /// enough to be invisible.
    private let interval: TimeInterval = 12 * 60 * 60
    private var timer: Timer?
    private var source: UpdateSource = GitHubReleaseSource()

    /// The version this build reports, which is what the release is compared to.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {}

    func start() {
        guard AppSettings.shared.automaticUpdateChecks else { return }
        // Not at launch: the first minutes belong to the user's session scan,
        // and a release published seconds ago can wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            Task { @MainActor in await UpdateController.shared.check() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await UpdateController.shared.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        state = .idle
    }

    // MARK: - Checking

    func check() async {
        // Never interrupt work already in flight.
        switch state {
        case .downloading, .readyToRelaunch: return
        default: break
        }

        state = .checking
        do {
            guard let release = try await source.latest() else { state = .idle; return }
            state = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .idle
        } catch {
            // A failed check is not worth telling anyone about — the machine may
            // simply be offline. Fall back to quiet and try again in 12 hours.
            state = .idle
        }
    }

    /// Compares dotted versions numerically, so 0.1.10 beats 0.1.9 (a plain
    /// string comparison gets that backwards).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    /// For `--test-update`: show the button without waiting for a real release.
    func showFakeUpdate() {
        state = .available(UpdateRelease(
            version: "99.0.0",
            downloadURL: URL(string: "https://example.invalid/Roundtable.dmg")!,
            pageURL: URL(string: "https://github.com/krak7602/roundtable/releases")!))
    }

    // MARK: - Installing

    func install() {
        guard let release = state.release else { return }
        state = .downloading(0)
        // Task inherits this @MainActor context, so the state assignments below
        // are already on the right actor; only the file work is pushed off it.
        Task {
            do {
                let dmg = try await UpdateInstaller.download(release.downloadURL) { fraction in
                    Task { @MainActor in UpdateController.shared.setProgress(fraction) }
                }
                try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.apply(dmg: dmg)
                }.value
                state = .readyToRelaunch
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Ignored unless a download is actually in flight, so a late callback from
    /// an abandoned attempt cannot drag the button back to a progress spinner.
    fileprivate func setProgress(_ f: Double) {
        guard case .downloading = state else { return }
        state = .downloading(f)
    }

    /// Hands over to the swap script and exits. The replacement cannot happen
    /// from inside the process being replaced.
    func relaunch() {
        UpdateInstaller.finish()
    }
}
