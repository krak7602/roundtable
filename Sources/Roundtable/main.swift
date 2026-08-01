import Foundation
import AppKit

// Entry point. `--scan` runs the adapters once headlessly (no SwiftUI, no
// notification center, no bundle needed) and exits. That's how we verify the
// engine against live data. Otherwise boot the menu-bar app.
let adapters: [any HarnessAdapter] = [
    ClaudeCodeAdapter(),
    CodexAdapter(),
    PiAdapter(harness: .pi, homeDir: ".pi"),
    PiAdapter(harness: .ohMyPi, homeDir: ".omp"),
]

if CommandLine.arguments.contains("--scan") {
    runScan(liveOnly: true)
} else if CommandLine.arguments.contains("--scan-all") {
    runScan(liveOnly: false)   // debug: skip the liveness gate to test parsers
} else if let idx = CommandLine.arguments.firstIndex(of: "--test-toast") {
    fireTestToast(count: CommandLine.arguments[safe: idx + 1] ?? "3", panel: false)
} else if let idx = CommandLine.arguments.firstIndex(of: "--test-toast-fs") {
    fireTestToast(count: CommandLine.arguments[safe: idx + 1] ?? "3", panel: true)
} else if CommandLine.arguments.contains("--fs-check") {
    let types = FullScreenDetector.currentSpaceTypes()
    print("current space type per display: \(types)")
    print("in full-screen space: \(FullScreenDetector.inFullScreenSpace())")
    print("focused screen frame: \(NSScreen.focused.frame)")
    for (i, s) in NSScreen.screens.enumerated() {
        print("  screen[\(i)] frame=\(s.frame) uuid=\(s.displayUUID ?? "?") fullScreen=\(FullScreenDetector.isFullScreen(s))")
    }
} else if CommandLine.arguments.contains("--test-orb") {
    // Spike: toggle the floating orb in the running app, to verify a draggable
    // (mouse-accepting) panel still draws over a full-screen app.
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.orbToggleName, object: nil, userInfo: nil, deliverImmediately: true)
    print("Toggled the floating orb in the running Roundtable.")
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
} else if CommandLine.arguments.contains("--test-update") {
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.testUpdateName, object: nil, userInfo: nil, deliverImmediately: true)
    print("Forced the update button on in the running Roundtable. Open the orb to see it.")
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
} else if CommandLine.arguments.contains("--proc-check") {
    let procs = ProcessCorrelator.liveHarnessProcesses()
    print("live harness processes: \(procs.count)")
    for p in procs { print("  comm=\(p.comm) cwd=\(p.cwd)") }
} else if CommandLine.arguments.contains("--hook") {
    forwardHookEvent()
} else if CommandLine.arguments.contains("--install-hooks") {
    print(HookInstaller.install(binaryPath: Bundle.main.executablePath ?? CommandLine.arguments[0]))
} else if CommandLine.arguments.contains("--uninstall-hooks") {
    print(HookInstaller.uninstall())
} else {
    RoundtableApp.main()
}

/// Claude Code invokes this (`Roundtable --hook`) for Notification/Stop events,
/// passing the event JSON on stdin. Forward it verbatim to the running app.
func forwardHookEvent() {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let json = String(data: data, encoding: .utf8) ?? "{}"

    // Diagnostic (opt-in): set ROUNDTABLE_HOOK_DEBUG=1 to record every hook
    // invocation to ~/.roundtable-hook.log. Off by default.
    if ProcessInfo.processInfo.environment["ROUNDTABLE_HOOK_DEBUG"] != nil {
        let line = "\(Date()) HOOK \(json.prefix(400))\n"
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".roundtable-hook.log")
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
        } else {
            try? line.data(using: .utf8)?.write(to: logURL)
        }
    }

    DistributedNotificationCenter.default().postNotificationName(
        MenuBarController.hookEventName,
        object: json,
        userInfo: nil,
        deliverImmediately: true)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
}

/// Signal the *running* app (via distributed notification) to fire N test
/// toasts, so we can watch the queue play out. `panel: true` forces the
/// floating-panel path (to verify over-full-screen behavior). Posts and exits.
func fireTestToast(count: String, panel: Bool) {
    let n = Int(count) ?? 3
    DistributedNotificationCenter.default().postNotificationName(
        MenuBarController.testToastName,
        object: panel ? "panel:\(n)" : "\(n)",
        userInfo: nil,
        deliverImmediately: true)
    print("Posted \(panel ? "panel " : "")test-toast(\(n)) to running Roundtable.")
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

func runScan(liveOnly: Bool) {
    let scanned = adapters.flatMap { $0.scan() }
    // Same join the app uses, so the CLI can't drift from what the menu shows.
    // `--scan-all` skips the liveness gate entirely, to test the parsers.
    let kept = liveOnly
        ? SessionStore.keepLive(scanned, liveProcesses: ProcessCorrelator.liveHarnessProcesses())
        : scanned
    let sessions = kept.sorted { a, b in
        if a.needsAttention != b.needsAttention { return a.needsAttention }
        return a.updatedAt > b.updatedAt
    }
    let fmt = DateFormatter()
    fmt.dateFormat = "MM-dd HH:mm"
    print("Roundtable scan — \(sessions.count) session(s)\n")
    for s in sessions {
        print("\(s.state.dot) [\(s.harness.shortName)] \(s.name)  ·  \(s.project)  ·  \(fmt.string(from: s.updatedAt))")
        print("    \(s.state.label): \(s.lastLine)")
    }
}
