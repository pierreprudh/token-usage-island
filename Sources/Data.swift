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

// A crossed 10% band (10, 20, 30 …). Carries a fresh id so the same band can
// re-fire after a window reset drops usage back down and it climbs again.
struct MilestoneEvent: Equatable {
    let id = UUID()
    let tool: String       // which provider crossed ("Claude", "Codex" …)
    let logoKey: String    // its mark for the lip
    let from: Int          // the band we were in (10, 20 …) — the roll starts here
    let bucket: Int        // the band just crossed into
    let percent: Double    // the reading that crossed it
    let metricLabel: String // which limit crossed — e.g. "Session · 5h" or "Weekly"
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var tools: [Tool] = []
    @Published var lastUpdated: Date?
    @Published var loading = false

    // User-defined provider order (by tool name). The provider on top is the one
    // surfaced in the hover lip. Persisted so a drag-reorder survives relaunch.
    private static let orderKey = "toolOrder"
    private var order: [String] = UserDefaults.standard.stringArray(forKey: UsageStore.orderKey)
        ?? ["Claude", "Codex", "OpenCode"]
    // Set whenever the headline percent crosses a new 10% band upward. The view
    // observes this to play the milestone pulse.
    @Published var milestone: MilestoneEvent?

    // Keep the last successful reading per tool so a transient failure
    // (e.g. a 429) doesn't blank out the numbers.
    private var lastGood: [String: Tool] = [:]

    // Milestone tracking — the last 10% band we saw per tool.
    private var lastBucket: [String: Int] = [:]

    // Politeness throttle. Claude's usage endpoint is shared per-account — the CLI
    // polls it too — so automatic triggers (file activity, backstop) fetch at most
    // once per `baseGap`, minimising overlap with the CLI's own requests.
    private var backstopTask: Task<Void, Never>?
    private var pendingRefresh = false
    private var lastRefreshAt: Date?
    private let baseGap: TimeInterval = 300      // ≥5 min between automatic fetches

    // Hard safety gate. Measured: the endpoint trips on the ~3rd request inside a
    // ~30 s sliding window that EVERY request re-extends (even 429s), and recovers
    // only after ~20–30 s of total silence. So `refresh()` enforces a floor between
    // any two requests, and a longer silence after a 429 — a single pending fire
    // (`flushTask`) coalesces everything, and every path (manual, launch, retry)
    // goes through this same gate so none can make the request that trips it.
    private var flushTask: Task<Void, Never>?
    private var nextAllowed = Date.distantPast
    private let minSpacing: TimeInterval = 30
    private var rlStrikes = 0
    private let coolDowns: [TimeInterval] = [45, 120, 300, 900, 1800]

    // Sort `tools` into the user's saved order. Names not in the order list keep
    // their fetch position at the end, so a newly-added provider still appears.
    private func applyOrder() {
        tools.sort {
            (order.firstIndex(of: $0.name) ?? .max) < (order.firstIndex(of: $1.name) ?? .max)
        }
    }

    // Persist the current on-screen order after a drag reorder, and re-sort so the
    // next refresh keeps it. Call this once the drop settles.
    func persistOrder() {
        order = tools.map { $0.name }
        UserDefaults.standard.set(order, forKey: Self.orderKey)
    }

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

    // The single choke point for hitting the network. Every path lands here, and
    // the hard gate below guarantees we never make the request that trips the
    // window: if we're inside the spacing floor or a 429 cooldown, we defer to one
    // pending fire instead of sending.
    func refresh() async {
        let now = Date()
        if now < nextAllowed {
            scheduleFlush(at: nextAllowed)
            return
        }
        nextAllowed = now.addingTimeInterval(minSpacing)   // reserve this slot up front
        lastRefreshAt = now
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
        applyOrder()
        self.lastUpdated = Date()
        self.loading = false

        // 429 recovery: go fully silent for a cooldown (measured recovery ≈ 20–30 s,
        // escalating only if it persists) and queue exactly one retry at the end of
        // that silence. On success, reset — a transient blip clears itself.
        let rateLimited = fresh.contains { $0.failed?.contains("Rate limited") ?? false }
        if rateLimited {
            rlStrikes = min(rlStrikes + 1, coolDowns.count)
            nextAllowed = Date().addingTimeInterval(coolDowns[rlStrikes - 1])
            scheduleFlush(at: nextAllowed)
        } else {
            rlStrikes = 0
        }

        detectMilestone()
    }

    // Coalesce every deferred request into a single fire at `when` — so no matter
    // how many triggers pile up during the gate, only one request goes out.
    private func scheduleFlush(at when: Date) {
        guard flushTask == nil else { return }
        let delay = max(0, when.timeIntervalSinceNow)
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.flushTask = nil
            await self?.refresh()
        }
    }

    // Politeness entry point for automatic triggers (file activity, backstop, card
    // open): fetch at most once per baseGap. The hard gate in refresh() still
    // applies underneath, so this only decides how often we *attempt*.
    func requestRefresh() {
        if let last = lastRefreshAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < baseGap {
                guard !pendingRefresh else { return }   // already one queued
                pendingRefresh = true
                let delay = baseGap - elapsed
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self?.pendingRefresh = false
                    await self?.refresh()
                }
                return
            }
        }
        Task { await refresh() }
    }

    // Fire a milestone when any tool's usage enters a higher 10% band. Each tool is
    // tracked independently off its highest metric; on a window reset the value
    // drops and we just re-arm the band without firing. If several cross in one
    // refresh, the highest band wins the spotlight.
    private func detectMilestone() {
        var winner: MilestoneEvent?
        for tool in tools {
            // The metric carrying the highest percent is the one that crossed — keep its
            // label so the milestone lip can say which limit (5 h session vs weekly).
            guard let top = tool.metrics
                .compactMap({ m in m.percent.map { (label: m.label, pct: $0) } })
                .max(by: { $0.pct < $1.pct }) else { continue }
            let bucket = Int(top.pct / 10) * 10
            let prev = lastBucket[tool.name]
            lastBucket[tool.name] = bucket
            guard let prev, bucket > prev, bucket > 0 else { continue }
            let ev = MilestoneEvent(tool: tool.name, logoKey: tool.logoKey,
                                    from: prev, bucket: bucket, percent: top.pct,
                                    metricLabel: top.label)
            if winner == nil || ev.bucket > winner!.bucket { winner = ev }
        }
        if let winner { milestone = winner }
    }

    // Slow idle backstop: a heartbeat that requests a refresh every 15 min so usage
    // stays fresh even with no local file activity (e.g. changes from another Mac).
    // It routes through the throttle, so it never fetches on top of a recent one.
    func startBackstop() {
        backstopTask?.cancel()
        backstopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900 * 1_000_000_000)   // 15 min
                if Task.isCancelled { break }
                self?.requestRefresh()
            }
        }
    }

    func stopBackstop() {
        backstopTask?.cancel()
        backstopTask = nil
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

let CODEX_ACCENT = Color(red: 0.470, green: 0.522, blue: 0.922)   // Codex periwinkle-blue #7885EB

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
