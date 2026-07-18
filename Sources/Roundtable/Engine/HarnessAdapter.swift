import Foundation

/// One adapter per harness (Claude Code, Codex, Pi/omp). Each knows how to turn
/// its harness's on-disk footprint into normalized `Session`s. Adapters are pure
/// readers with no UI and no global state, so the engine can run them off the
/// main thread.
protocol HarnessAdapter: Sendable {
    var harness: Harness { get }

    /// Scan the harness's data directory and return the current set of sessions.
    /// Called on a background queue on every poll tick.
    func scan() -> [Session]
}

/// Incremental parse cache: a transcript whose mtime is unchanged since we last
/// parsed it isn't being written, so its `Session` is reused instead of re-read
/// and re-parsed. In steady state only actively-written sessions are re-parsed,
/// turning an every-2s "parse every file" loop into "parse only what changed".
///
/// Accessed only from the store's serial scan queue, so `@unchecked Sendable` is
/// safe (no concurrent mutation).
final class TranscriptCache: @unchecked Sendable {
    private var entries: [String: (mtime: Date, session: Session)] = [:]
    private var seen: Set<String> = []

    /// Return the cached session if `mtime` matches; otherwise parse, cache, return.
    func resolve(path: String, mtime: Date, parse: () -> Session?) -> Session? {
        seen.insert(path)
        if let e = entries[path], e.mtime == mtime { return e.session }
        let session = parse()
        entries[path] = session.map { (mtime, $0) }
        return session
    }

    /// Drop cache entries for files not seen this scan (deleted / aged out).
    func endScan() {
        entries = entries.filter { seen.contains($0.key) }
        seen.removeAll()
    }
}

/// Shared helper: read the last `maxBytes` of a file without loading the whole
/// thing. Transcripts grow to many MB; we only ever need the tail to know state.
enum TailReader {
    static func lastChunk(of path: String, maxBytes: Int = 128 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            // Lossy decode: a tail window can start mid-multibyte-char, which
            // makes strict UTF-8 decoding fail and silently drops the session.
            // The mangled leading fragment is skipped by jsonLines anyway.
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// Read just the first line of a file. Codex's `session_meta` (with cwd) is
    /// always line 1, and the tail chunk of a big transcript may not include it.
    static func firstLine(of path: String) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        while buffer.count < 256 * 1024 {
            guard let next = try? handle.read(upToCount: 16 * 1024), !next.isEmpty else { break }
            buffer.append(next)
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<nl]
                return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            }
        }
        return nil
    }

    /// Read the first `maxBytes` of a file, for formats whose header/metadata
    /// (cwd, title) lives at the start and may fall outside the tail on big files.
    /// The final line of the chunk may be a fragment; `jsonLines` tolerates it.
    static func headChunk(of path: String, maxBytes: Int = 64 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Parse the tail into JSON objects, newest last. The first line of a
    /// mid-file chunk may be a fragment, so callers should tolerate a dropped head.
    static func jsonLines(from chunk: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for raw in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            out.append(obj)
        }
        return out
    }
}
