import Foundation
import AppKit

/// Opt-in diagnostic logging, built for bug reports.
///
/// Off by default and free when off: the `enabled` check is a static bool and
/// every message is an autoclosure, so disabled call sites never even build
/// their strings. Turn it on with either:
///
///     defaults write dev.rahulkrishna.roundtable debugLogging -bool true
///     ROUNDTABLE_DEBUG=1 ./Roundtable.app/Contents/MacOS/Roundtable
///
/// then relaunch (the flag is read once at startup, so one capture covers one
/// run). Lines land in `~/Library/Logs/Roundtable/debug.log` — a plain file in
/// the conventional location, because the point is that a user can attach it to
/// an issue, and "find it in Console.app" is where bug reports go to die.
///
/// The log records decision points, not content: session states, what the
/// attention ledger announced and why, hook events, focus and injection
/// attempts. It inevitably contains project names and paths — the docs say so
/// where the flag is documented.
enum DebugLog {
    static let enabled: Bool =
        ProcessInfo.processInfo.environment["ROUNDTABLE_DEBUG"] != nil
        || UserDefaults.standard.bool(forKey: "debugLogging")

    /// Tags are short and stable ("scan", "announce", "hook", "inject", "focus")
    /// so a report can be grepped by subsystem.
    static func log(_ tag: String, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(stamp()) [\(tag)] \(message())\n"
        queue.async { write(line) }
    }

    static var path: String { url.path }

    // MARK: - Plumbing

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Roundtable", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    /// All writes go through one serial queue: callers span the main actor and
    /// the scan/injection queues, and interleaved half-lines would defeat the
    /// entire purpose of the file. The sink's mutable state (file handle, byte
    /// count) is confined to that queue — the @unchecked Sendable is what tells
    /// the compiler the confinement is deliberate.
    private static let queue = DispatchQueue(label: "roundtable.debuglog", qos: .utility)
    private static let sink = Sink()

    private final class Sink: @unchecked Sendable {
        var handle: FileHandle?
        var bytesWritten: UInt64 = 0
    }

    private static let rotateAt: UInt64 = 10 * 1024 * 1024

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func stamp() -> String { formatter.string(from: Date()) }

    /// Runs once, lazily, on the queue. Rotates a large previous log aside so
    /// the file never grows without bound across many debug sessions, then
    /// opens with a header that saves the "what version are you on?" round-trip.
    private static func open() {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
           size > rotateAt {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        sink.handle = try? FileHandle(forWritingTo: url)
        _ = try? sink.handle?.seekToEnd()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let header = "\(stamp()) [start] Roundtable \(version) · macOS \(os)\n"
        sink.handle?.write(Data(header.utf8))
    }

    private static func write(_ line: String) {
        if sink.handle == nil { open() }
        guard let handle = sink.handle else { return }
        let data = Data(line.utf8)
        handle.write(data)
        sink.bytesWritten += UInt64(data.count)
        if sink.bytesWritten > rotateAt {
            // Close and let the next write reopen — open() rotates the file
            // aside when it finds it oversized.
            try? handle.close()
            sink.handle = nil
            sink.bytesWritten = 0
        }
    }
}
