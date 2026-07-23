import Foundation
import SwiftUI
import AppKit

// MARK: - Models

struct Metric: Identifiable {
    let id = UUID()
    let label: String        // "Session · 5h"
    let percent: Double?      // 0...100, nil if not a % metric
    let detail: String        // "Resets 17:30" or "$14.90 · 31M tok"
}

struct Tool: Identifiable {
    let id = UUID()
    let name: String
    let logoKey: String       // "claude" / "codex" / "opencode"
    let accent: Color
    var metrics: [Metric]
    var subtitle: String?     // "Plus plan" / "pay-as-you-go"
    var failed: String?       // error message if fetch failed
}

// Bundled provider logos (loaded once). NSImage renders the SVG natively.
enum Logos {
    static let claude = load("claude-code-logo", "png")
    static let codex = load("codex-logo", "png")
    static let opencodeDark = load("opencode-logo-dark", "svg")    // light block — for dark bg
    static let opencodeLight = load("opencode-logo-light", "svg")  // dark block — for light bg

    private static func load(_ name: String, _ ext: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: ext).flatMap { NSImage(contentsOf: $0) }
    }
    static func named(_ key: String) -> NSImage? {
        switch key {
        case "claude": return claude
        case "codex": return codex
        case "opencode": return opencodeDark
        default: return nil
        }
    }
}

// Severity color from a percent (shared across all tools for consistency)
func barColor(_ pct: Double?, accent: Color) -> Color {
    guard let p = pct else { return accent }
    if p >= 90 { return Color(red: 0.94, green: 0.33, blue: 0.31) }   // red
    if p >= 70 { return Color(red: 0.96, green: 0.68, blue: 0.20) }   // amber
    return accent
}

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    @Published var tools: [Tool] = []
    @Published var lastUpdated: Date?
    @Published var loading = false

    // Keep the last successful reading per tool so a transient failure
    // (e.g. a 429) doesn't blank out the numbers.
    private var lastGood: [String: Tool] = [:]

    // A specific Claude metric percent (e.g. "Session", "Weekly").
    func claudePercent(_ needle: String) -> Double? {
        tools.first(where: { $0.name == "Claude" })?
            .metrics.first(where: { $0.label.range(of: needle, options: .caseInsensitive) != nil })?
            .percent
    }

    // Headline shown in the collapsed island: Claude weekly %, falling back to max.
    var headlinePercent: Double? {
        if let claude = tools.first(where: { $0.name == "Claude" }),
           let weekly = claude.metrics.first(where: { $0.label.contains("Weekly") })?.percent {
            return weekly
        }
        return tools.flatMap { $0.metrics }.compactMap { $0.percent }.max()
    }

    func refresh() async {
        loading = true
        async let claude = fetchClaude()
        async let codex = fetchCodex()
        async let opencode = fetchOpenCode()
        let fresh = await [claude, codex, opencode]

        self.tools = fresh.map { t in
            if t.failed == nil && !t.metrics.isEmpty {
                lastGood[t.name] = t
                return t
            }
            // Fall back to the last good reading if we have one.
            return lastGood[t.name] ?? t
        }
        self.lastUpdated = Date()
        self.loading = false
    }
}

// MARK: - Process helper

func runProcess(_ launchPath: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do {
        try p.run()
    } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Date formatting

private let isoFmt: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoFmtNoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoFmt.date(from: s) ?? isoFmtNoFrac.date(from: s)
}

func resetDetail(_ date: Date?) -> String {
    guard let date else { return "" }
    let now = Date()
    let secs = date.timeIntervalSince(now)
    if secs <= 0 { return "resetting…" }
    let df = DateFormatter()
    df.locale = Locale.current
    if secs < 24 * 3600 {
        df.dateFormat = "HH:mm"
        return "Resets \(df.string(from: date))"
    } else {
        df.dateFormat = "EEE HH:mm"
        return "Resets \(df.string(from: date))"
    }
}

// MARK: - Claude (live endpoint)

let CLAUDE_ACCENT = Color(red: 0.85, green: 0.47, blue: 0.30)   // rust/orange

func fetchClaude() async -> Tool {
    var tool = Tool(name: "Claude", logoKey: "claude", accent: CLAUDE_ACCENT, metrics: [], subtitle: nil, failed: nil)

    guard let raw = runProcess("/usr/bin/security",
        ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
        let data = raw.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let oauth = json["claudeAiOauth"] as? [String: Any],
        let token = oauth["accessToken"] as? String
    else {
        tool.failed = "No credentials. Sign in with Claude Code."
        return tool
    }
    if let sub = oauth["subscriptionType"] as? String {
        tool.subtitle = sub.capitalized + " plan"
    }

    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("claude-cli/2.1.218 (external, cli)", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 12

    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 {
            tool.failed = "Token expired. Reopen Claude Code."
            return tool
        }
        if status == 429 {
            tool.failed = "Rate limited — retry shortly."
            return tool
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            tool.failed = "Bad response."
            return tool
        }
        if let fh = json["five_hour"] as? [String: Any],
           let util = fh["utilization"] as? Double {
            tool.metrics.append(Metric(label: "Session · 5h", percent: util,
                                       detail: resetDetail(parseISO(fh["resets_at"] as? String))))
        }
        if let sd = json["seven_day"] as? [String: Any],
           let util = sd["utilization"] as? Double {
            tool.metrics.append(Metric(label: "Weekly", percent: util,
                                       detail: resetDetail(parseISO(sd["resets_at"] as? String))))
        }
        if tool.metrics.isEmpty { tool.failed = "No usage data." }
    } catch {
        tool.failed = "Offline."
    }
    return tool
}

// MARK: - Codex (last rate_limits from newest session log)

let CODEX_ACCENT = Color(red: 0.20, green: 0.72, blue: 0.55)   // teal/green

func fetchCodex() async -> Tool {
    var tool = Tool(name: "Codex", logoKey: "codex", accent: CODEX_ACCENT, metrics: [], subtitle: nil, failed: nil)

    guard let fileURL = newestCodexSession(),
          let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
        tool.failed = "No Codex sessions."
        return tool
    }

    // Find the LAST line containing rate_limits.
    var lastRL: [String: Any]?
    for line in content.split(separator: "\n") where line.contains("rate_limits") {
        if let d = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d),
           let rl = findKey("rate_limits", in: obj) as? [String: Any] {
            lastRL = rl
        }
    }
    guard let rl = lastRL else {
        tool.failed = "No rate-limit data yet."
        return tool
    }
    if let plan = rl["plan_type"] as? String { tool.subtitle = plan.capitalized + " plan" }

    if let primary = rl["primary"] as? [String: Any],
       let used = primary["used_percent"] as? Double {
        let window = primary["window_minutes"] as? Double ?? 0
        let label = window >= 10080 ? "Weekly" : (window >= 300 ? "Session" : "Limit")
        var detail = "as of last run"
        if let resetEpoch = primary["resets_at"] as? Double {
            detail = resetDetail(Date(timeIntervalSince1970: resetEpoch))
        }
        tool.metrics.append(Metric(label: label, percent: used, detail: detail))
    }
    if let secondary = rl["secondary"] as? [String: Any],
       let used = secondary["used_percent"] as? Double {
        var detail = ""
        if let resetEpoch = secondary["resets_at"] as? Double {
            detail = resetDetail(Date(timeIntervalSince1970: resetEpoch))
        }
        tool.metrics.append(Metric(label: "Secondary", percent: used, detail: detail))
    }
    if tool.metrics.isEmpty { tool.failed = "No rate-limit data yet." }
    return tool
}

// Find newest .jsonl under ~/.codex/sessions (sync — enumerator isn't async-safe).
func newestCodexSession() -> URL? {
    let sessionsDir = ("~/.codex/sessions" as NSString).expandingTildeInPath
    let fm = FileManager.default
    guard let en = fm.enumerator(at: URL(fileURLWithPath: sessionsDir),
                                 includingPropertiesForKeys: [.contentModificationDateKey]) else {
        return nil
    }
    var newest: (URL, Date)?
    for case let url as URL in en where url.pathExtension == "jsonl" {
        let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if newest == nil || d > newest!.1 { newest = (url, d) }
    }
    return newest?.0
}

// recursively find a key in a nested JSON object
func findKey(_ key: String, in obj: Any) -> Any? {
    if let dict = obj as? [String: Any] {
        if let v = dict[key] { return v }
        for v in dict.values {
            if let r = findKey(key, in: v) { return r }
        }
    } else if let arr = obj as? [Any] {
        for v in arr {
            if let r = findKey(key, in: v) { return r }
        }
    }
    return nil
}

// MARK: - OpenCode (SQLite aggregate — pay-as-you-go, no plan limit)

let OPENCODE_ACCENT = Color(red: 0.45, green: 0.55, blue: 0.95)   // indigo

func fetchOpenCode() async -> Tool {
    var tool = Tool(name: "OpenCode", logoKey: "opencode", accent: OPENCODE_ACCENT,
                    metrics: [], subtitle: "pay-as-you-go", failed: nil)

    let db = ("~/.local/share/opencode/opencode.db" as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: db) else {
        tool.failed = "No OpenCode database."
        return tool
    }
    let weekAgoMs = Int((Date().timeIntervalSince1970 - 7 * 86400) * 1000)
    let query = """
    SELECT ROUND(SUM(json_extract(data,'$.cost')),2),
           SUM(COALESCE(json_extract(data,'$.tokens.input'),0)
             + COALESCE(json_extract(data,'$.tokens.output'),0)
             + COALESCE(json_extract(data,'$.tokens.cache.read'),0)
             + COALESCE(json_extract(data,'$.tokens.cache.write'),0))
    FROM message WHERE time_created > \(weekAgoMs);
    """
    guard let out = runProcess("/usr/bin/sqlite3", [db, query]) else {
        tool.failed = "Query failed."
        return tool
    }
    let parts = out.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    let cost = Double(parts.first ?? "") ?? 0
    let toks = Double(parts.count > 1 ? parts[1] : "") ?? 0
    tool.metrics.append(Metric(label: "This week", percent: nil,
                               detail: String(format: "$%.2f · %@ tok", cost, humanTokens(toks))))
    return tool
}

func humanTokens(_ n: Double) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
    return String(format: "%.0f", n)
}
