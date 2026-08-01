import Foundation
import AppKit
import Security

enum UpdateError: LocalizedError {
    case notAnAppBundle
    case notWritable(String)
    case downloadFailed
    case mountFailed
    case noAppInImage
    case unidentifiedTeam
    case signatureRejected(String)

    var errorDescription: String? {
        switch self {
        case .notAnAppBundle:
            return "Roundtable is not running from an app bundle, so it cannot replace itself."
        case .notWritable(let path):
            return "No permission to update \(path). Move Roundtable to your Applications folder and try again."
        case .downloadFailed:
            return "The download did not complete."
        case .mountFailed:
            return "The downloaded disk image could not be opened."
        case .noAppInImage:
            return "The downloaded disk image did not contain Roundtable."
        case .unidentifiedTeam:
            return "This copy of Roundtable is unsigned, so an update cannot be verified against it."
        case .signatureRejected(let why):
            return "The downloaded update failed verification and was discarded. \(why)"
        }
    }
}

/// Downloads, verifies and swaps in a new build.
///
/// The verification is the point of this file. An updater that installs whatever
/// it downloads is a way to take over every machine the app runs on, so the new
/// build must prove it was signed by the *same team as the running copy* before
/// it is allowed anywhere near the bundle. The team is read from our own
/// signature at runtime rather than written down, so there is no constant to
/// forget to change, and an unsigned local build refuses to self-update at all.
enum UpdateInstaller {

    // MARK: - Download

    static func download(_ url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let expected = response.expectedContentLength
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtable-update-\(UUID().uuidString).dmg")

        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(expected)) }
        var lastReported = 0.0
        for try await byte in bytes {
            data.append(byte)
            if expected > 0 {
                let fraction = Double(data.count) / Double(expected)
                // Only surface visible movement; a per-byte publish would spend
                // more time redrawing than downloading.
                if fraction - lastReported > 0.01 {
                    lastReported = fraction
                    onProgress(fraction)
                }
            }
        }
        try data.write(to: destination)
        onProgress(1)
        return destination
    }

    // MARK: - Verify and stage

    /// Mounts the image, checks the app inside it, and stages a verified copy
    /// next to the installed one. Nothing is replaced yet — that happens in
    /// finish(), after the app has quit.
    static func apply(dmg: URL) throws {
        let installed = Bundle.main.bundleURL
        guard installed.pathExtension == "app" else { throw UpdateError.notAnAppBundle }

        let parent = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }

        let team = try ownTeamIdentifier()

        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtable-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil",
                  ["attach", dmg.path, "-mountpoint", mount.path, "-nobrowse", "-readonly", "-noautoopen"]) else {
            throw UpdateError.mountFailed
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            try? FileManager.default.removeItem(at: mount)
            try? FileManager.default.removeItem(at: dmg)
        }

        let newApp = mount.appendingPathComponent("Roundtable.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError.noAppInImage }

        try verify(newApp, matchesTeam: team)

        // ditto, not copyItem: it preserves the signature, extended attributes
        // and symlinks the bundle depends on. A plain copy can invalidate the
        // very signature that was just checked.
        let staged = parent.appendingPathComponent(".Roundtable-update.app")
        try? FileManager.default.removeItem(at: staged)
        guard run("/usr/bin/ditto", [newApp.path, staged.path]) else { throw UpdateError.downloadFailed }

        // Check again where it landed. The copy is what will actually be run,
        // and it is the thing an attacker with write access to the staging
        // directory would swap.
        try verify(staged, matchesTeam: team)
    }

    /// The team identifier of the running copy, from its own signature.
    private static func ownTeamIdentifier() throws -> String {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { throw UpdateError.unidentifiedTeam }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.unidentifiedTeam
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty
        else { throw UpdateError.unidentifiedTeam }
        return team
    }

    /// Valid Apple-rooted signature, from the same team as us. Both halves
    /// matter: the anchor alone would accept any Developer ID app on the
    /// internet, and the team alone would accept a forgery.
    private static func verify(_ app: URL, matchesTeam team: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signatureRejected("It is not signed.")
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.signatureRejected("The check could not be built.")
        }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(
            code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement, &error)
        guard status == errSecSuccess else {
            let why = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "Status \(status)."
            throw UpdateError.signatureRejected(why)
        }
    }

    // MARK: - Swap

    /// Replaces the bundle and relaunches. A process cannot overwrite the bundle
    /// it is executing from, so this hands the job to a short script that waits
    /// for us to exit first, then quits.
    @MainActor
    static func finish() {
        let installed = Bundle.main.bundleURL
        let staged = installed.deletingLastPathComponent().appendingPathComponent(".Roundtable-update.app")
        guard FileManager.default.fileExists(atPath: staged.path) else { return }

        let script = """
        #!/bin/sh
        # Wait for Roundtable to exit before touching the bundle it is running from.
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(installed.path)"
        /usr/bin/ditto "\(staged.path)" "\(installed.path)"
        rm -rf "\(staged.path)"
        /usr/bin/open "\(installed.path)"
        rm -f "$0"
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtable-swap-\(UUID().uuidString).sh")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [url.path]
        try? task.run()

        NSApplication.shared.terminate(nil)
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
