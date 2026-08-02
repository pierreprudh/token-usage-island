import Foundation
import SQLite3

// Everything in the core that is OS-specific lives here, and nothing else in
// Sources/Core touches the operating system directly. That is the point of the file:
// porting the fetch layer to another OS means reimplementing this one file, not
// hunting platform assumptions through the parsers.
//
// Three things are genuinely platform-bound — where credentials are kept, where the
// coding tools put their data, and how we talk to SQLite. Each gets a seam below.

// MARK: - Paths
//
// Overridable by environment so the fetchers can be pointed at fixtures, and so a
// port to an OS with different conventions (%APPDATA% on Windows, a non-default
// XDG_DATA_HOME on Linux) needs no code change to try out.
enum Paths {
    static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

    private static func env(_ key: String, default def: String) -> String {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return expand(v) }
        return expand(def)
    }

    static var codexSessions: String { env("TUI_CODEX_SESSIONS", default: "~/.codex/sessions") }
    static var opencodeDB: String { env("TUI_OPENCODE_DB", default: "~/.local/share/opencode/opencode.db") }
    static var claudeCredentialsFile: String {
        env("TUI_CLAUDE_CREDENTIALS", default: "~/.claude/.credentials.json")
    }
}

// MARK: - Process helper

// Run a child and return its stdout, or nil if it failed or outstayed `timeout`.
//
// The timeout is not paranoia: `security find-generic-password` blocks for as long
// as the Keychain permission dialog is up, and that dialog is the documented
// first-launch step. Unbounded, a fetch that hits it never returns — `loading` stays
// true and the refresh arrow spins forever. 60 s is far longer than a human needs to
// click "Always Allow" and far shorter than forever.
func runProcess(_ launchPath: String, _ args: [String], timeout: TimeInterval = 60) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    // Discard stderr at the file-descriptor level rather than handing the child a
    // Pipe nobody ever reads: once a child writes more than the pipe buffer (~64 KB)
    // it blocks on the write, and `waitUntilExit()` below then blocks on it forever.
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
    } catch { return nil }
    // Fires only if the child is still alive at the deadline; cancelled on the
    // normal path below, and no-ops if the process exits while it's in flight.
    let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    // Read before waiting: draining stdout is what lets the child finish writing and
    // exit. Terminating it closes the pipe's write end, so this returns either way.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    watchdog.cancel()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Claude credentials

struct ClaudeCredentials {
    let accessToken: String
    let subscriptionType: String?
}

// Where the Claude Code OAuth token comes from. macOS keeps it in the Keychain;
// other platforms write it to a file. Both encode the same `claudeAiOauth` object,
// so only the retrieval differs — which is exactly what this seam isolates.
protocol CredentialSource {
    func claudeCredentials() -> ClaudeCredentials?
}

// Shared decoder for the credential blob, whatever produced it.
private func decodeClaudeBlob(_ data: Data) -> ClaudeCredentials? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String
    else { return nil }
    return ClaudeCredentials(accessToken: token,
                             subscriptionType: oauth["subscriptionType"] as? String)
}

#if os(macOS)
struct KeychainCredentials: CredentialSource {
    func claudeCredentials() -> ClaudeCredentials? {
        guard let raw = runProcess("/usr/bin/security",
                                   ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
              let data = raw.data(using: .utf8)
        else { return nil }
        return decodeClaudeBlob(data)
    }
}
#endif

struct FileCredentials: CredentialSource {
    var path: String = Paths.claudeCredentialsFile
    func claudeCredentials() -> ClaudeCredentials? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return decodeClaudeBlob(data)
    }
}

// Try each source in turn. On macOS the Keychain is the documented location and goes
// first, but some installs also leave the file behind, so falling through to it costs
// nothing and covers a setup the Keychain-only version simply failed on.
struct DefaultCredentials: CredentialSource {
    var sources: [CredentialSource] = {
        #if os(macOS)
        return [KeychainCredentials(), FileCredentials()]
        #else
        return [FileCredentials()]
        #endif
    }()
    func claudeCredentials() -> ClaudeCredentials? {
        for s in sources {
            if let c = s.claudeCredentials() { return c }
        }
        return nil
    }
}

// MARK: - SQLite

// Read-only query returning the first row's columns as Doubles (NULL -> nil).
//
// This replaces shelling out to /usr/bin/sqlite3. The subprocess worked, but it made
// a SQLite read cost a fork+exec, gave us no control over how the database is opened,
// and meant parsing numbers back out of pipe-delimited text. It also assumed a binary
// at a fixed absolute path, which is precisely the kind of assumption that doesn't
// survive a port. Integer parameters are bound rather than interpolated.
//
// SQLITE_OPEN_READONLY matters here: OpenCode's database is in WAL mode (there's a
// -shm alongside it) and is often open in another process while we read.
func sqliteFirstRow(dbPath: String, sql: String, params: [Int64] = []) -> [Double?]? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return nil
    }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }

    for (i, v) in params.enumerated() {
        sqlite3_bind_int64(stmt, Int32(i + 1), v)
    }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return (0..<Int(sqlite3_column_count(stmt))).map { i in
        let col = Int32(i)
        return sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
    }
}
