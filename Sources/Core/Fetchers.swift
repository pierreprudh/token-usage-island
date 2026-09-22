import Foundation

// The three providers. Everything here is Foundation plus the seams in Platform.swift
// — no UI framework, no assumption about who is displaying the result. The island and
// the `usage status` CLI both read through this file unchanged.

// MARK: - Claude (live endpoint)

func _fetchClaude(credentials: CredentialSource = DefaultCredentials()) async -> Tool {
    var tool = Tool(name: "Claude", logoKey: "claude", accent: CLAUDE_ACCENT, metrics: [], subtitle: nil, failed: nil)

    guard let creds = credentials.claudeCredentials() else {
        tool.failed = "No credentials. Sign in with Claude Code."
        return tool
    }
    if let sub = creds.subscriptionType {
        tool.subtitle = sub.capitalized + " plan"
    }

    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
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

// MARK: - Codex (rate_limits events from the session logs)

// One `rate_limits` object as Codex logs it, plus where and when it was seen.
//
// Since Codex 0.155 a session can report more than one limit. The plan allowance —
// the 5 h and weekly windows `/status` shows — is `limit_id: "codex"`; older logs
// have no `limit_id` at all and mean the same thing. Alongside it, Codex Desktop
// routes eligible Plus/Pro accounts onto "Luna Reserve", a separate allowance that
// arrives as `limit_id: "base_model_inference"`, `limit_name: "gpt-reserve"`, with a
// single weekly window and a null `secondary`. Once a session is on the reserve, the
// plan bucket stops being written, so "the last rate_limits line" is no longer the
// plan reading: it shipped as a bare "Weekly 0%" with the Session row gone.
struct CodexRateLimit {
    let bucket: String          // "codex", "base_model_inference", "premium", …
    let name: String?           // limit_name — "gpt-reserve" for Luna Reserve
    let at: Date?               // the line's timestamp, nil on logs that lack one
    let raw: [String: Any]

    var isPlan: Bool { bucket == "codex" }
    var primary: [String: Any]? { raw["primary"] as? [String: Any] }
    var secondary: [String: Any]? { raw["secondary"] as? [String: Any] }
    var planType: String? { raw["plan_type"] as? String }
}

// Every `rate_limits` line in `text`, in file order. Lines that don't parse are
// skipped — a truncated last line must not cost the reading.
func parseCodexRateLimits(_ text: String) -> [CodexRateLimit] {
    var out: [CodexRateLimit] = []
    for line in text.split(separator: "\n") where line.contains("rate_limits") {
        guard let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let rl = findKey("rate_limits", in: obj) as? [String: Any] else { continue }
        let ts = (obj as? [String: Any])?["timestamp"] as? String
        out.append(CodexRateLimit(bucket: rl["limit_id"] as? String ?? "codex",
                                  name: rl["limit_name"] as? String,
                                  at: parseISO(ts), raw: rl))
    }
    return out
}

func _fetchCodex(sessionsDir: String = Paths.codexSessions, now: Date = Date()) async -> Tool {
    var tool = Tool(name: "Codex", logoKey: "codex", accent: CODEX_ACCENT, metrics: [], subtitle: nil, failed: nil)

    let sessions = codexSessionsNewestFirst(in: sessionsDir)
    guard let newest = sessions.first,
          let content = tailContaining(newest, needle: "rate_limits") else {
        tool.failed = "No Codex sessions."
        return tool
    }
    let current = parseCodexRateLimits(content)

    // The plan reading. Usually in the current session; when that session has spent
    // its whole logged life on the reserve, the last plan line is in an earlier one,
    // so walk back. The walk is bounded — thirty sessions is weeks of use.
    var plan = latestCodexPlanReading(in: newest, seen: current)
    if plan == nil {
        for url in sessions.dropFirst().prefix(30) {
            if let hit = latestCodexPlanReading(in: url) { plan = hit; break }
        }
    }
    // The reserve only matters while the current session is drawing on it.
    let reserve = current.last { !$0.isPlan && $0.primary != nil }

    if let type = (plan ?? reserve)?.planType { tool.subtitle = type.capitalized + " plan" }

    if let plan {
        if let primary = plan.primary, let used = primary["used_percent"] as? Double {
            let window = primary["window_minutes"] as? Double ?? 0
            let label = window >= 10080 ? "Weekly" : (window >= 300 ? "Session" : "Limit")
            let (pct, detail) = codexWindowReading(used: used, resetsAt: primary["resets_at"] as? Double,
                                                   seenAt: plan.at, now: now)
            // `slot` disambiguates the primary/secondary pair in the milestone bucket key
            // when both happen to share a label (e.g. two weekly windows).
            tool.metrics.append(Metric(label: label, percent: pct, detail: detail, slot: "primary"))
        }
        if let secondary = plan.secondary, let used = secondary["used_percent"] as? Double {
            // Name it by its window like `primary` does — "Secondary" told the milestone
            // lip nothing, so a Codex weekly crossing showed a bare "20%" with no period tag.
            let window = secondary["window_minutes"] as? Double ?? 0
            let label = window >= 10080 ? "Weekly" : (window >= 300 ? "Session" : "Secondary")
            let (pct, detail) = codexWindowReading(used: used, resetsAt: secondary["resets_at"] as? Double,
                                                   seenAt: plan.at, now: now)
            tool.metrics.append(Metric(label: label, percent: pct, detail: detail, slot: "secondary"))
        }
    }
    if let reserve, let primary = reserve.primary, let used = primary["used_percent"] as? Double {
        let label = reserve.name == "gpt-reserve" ? "Reserve" : (reserve.name ?? reserve.bucket)
        let (pct, detail) = codexWindowReading(used: used, resetsAt: primary["resets_at"] as? Double,
                                               seenAt: reserve.at, now: now)
        tool.metrics.append(Metric(label: label, percent: pct, detail: detail, slot: "reserve"))
    }
    if tool.metrics.isEmpty { tool.failed = "No rate-limit data yet." }
    return tool
}

// Codex serialises compactly, so the plan bucket's tag is byte-stable in the log.
private let codexPlanNeedle = "\"limit_id\":\"codex\""

// The last plan-bucket line in `url`, or nil if the session never wrote one.
//
// The first pass is the cheap one: the tail that holds the newest `rate_limits` line,
// which `seen` supplies when the caller has already read it. That is the whole answer
// for legacy logs and for a session still on the plan. A session that has moved onto
// the reserve fills that tail with reserve lines only, and the plan line it wrote
// before switching sits megabytes deeper — the real 09/21 log had it 2.5 MB from EOF.
// Growing towards the plan tag itself finds it in one more read; only a session that
// was on the reserve from its first turn reads to the start and comes back empty.
func latestCodexPlanReading(in url: URL, seen: [CodexRateLimit]? = nil) -> CodexRateLimit? {
    let first = seen ?? (tailContaining(url, needle: "rate_limits").map(parseCodexRateLimits) ?? [])
    if let hit = first.last(where: \.isPlan) { return hit }
    guard !first.isEmpty, let deeper = tailContaining(url, needle: codexPlanNeedle) else { return nil }
    return parseCodexRateLimits(deeper).last(where: \.isPlan)
}

// Percent and detail for one window, honest about the reading's age. A plan line can
// be a day old once the session is on the reserve, and a 5 h window has rolled over by
// then: showing its last 70% as current would be wrong, so a passed reset reads as 0%
// and says why. A reading older than an hour whose window is still open keeps its
// value and appends when it was taken. The " · " separator matters — the collapsed
// lip shows only the text before the first one, so the reset time stays up front.
func codexWindowReading(used: Double, resetsAt: Double?, seenAt: Date?, now: Date) -> (Double, String) {
    guard let resetsAt else { return (used, seenAt.map { "as of " + clockDetail($0, now: now) } ?? "as of last run") }
    let reset = Date(timeIntervalSince1970: resetsAt)
    if reset <= now, let seenAt, seenAt < reset { return (0, "Reset since last run") }
    var detail = resetDetail(reset, now: now)
    if let seenAt, now.timeIntervalSince(seenAt) > 3600 {
        detail += " · as of " + clockDetail(seenAt, now: now)
    }
    return (used, detail)
}

// Every .jsonl under the Codex sessions dir, newest modification first (sync — the
// enumerator isn't async-safe).
func codexSessionsNewestFirst(in dir: String) -> [URL] {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: URL(fileURLWithPath: dir),
                                 includingPropertiesForKeys: [.contentModificationDateKey]) else {
        return []
    }
    var found: [(URL, Date)] = []
    for case let url as URL in en where url.pathExtension == "jsonl" {
        let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        found.append((url, d))
    }
    return found.sorted { $0.1 > $1.1 }.map(\.0)
}

// Read the tail of a file (default 64 KB) without slurping the whole thing. Codex
// session logs can reach tens of MB; the latest `rate_limits` line is almost always
// in the last few KB, so this gives us the same answer in a tiny fraction of the I/O
// and decoding work. If we start mid-line, drop the first partial line.
//
// The partial-line trim happens on *bytes*, before decoding, and that ordering is
// load-bearing. A 64 KB window opens wherever it opens, and session logs are mostly
// prompt text — emoji, accents, CJK — so the window routinely starts inside a
// multi-byte character. Decoding first would simply fail there and make a perfectly
// good log report as "No Codex sessions.". A 0x0A byte can never appear inside a
// UTF-8 multi-byte sequence (continuation bytes are all ≥ 0x80), so slicing after
// the first newline lands on a character boundary by construction.
func tailOfFile(_ url: URL, bytes: Int = 1 << 16) -> String? {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? Int, size > 0,
          let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let toRead = min(size, bytes)
    let offset = UInt64(size - toRead)
    do {
        try handle.seek(toOffset: offset)
        var data = handle.readData(ofLength: toRead)
        if offset > 0 {
            // No newline in the window means a single line longer than `bytes`, so the
            // tail is a fragment that no JSON line can be parsed out of. Fall back to
            // the whole file rather than silently reporting no data.
            guard let nl = data.firstIndex(of: 0x0A) else {
                guard let whole = try? Data(contentsOf: url) else { return nil }
                return String(decoding: whole, as: UTF8.self)
            }
            data = data[data.index(after: nl)...]
        }
        // Repairing decode rather than the failable one: after the byte trim the slice
        // starts on a boundary, and a malformed byte in the log itself should cost us
        // that one line at JSON-parse time, not the entire reading.
        return String(decoding: data, as: UTF8.self)
    } catch {
        return nil
    }
}

// Return the smallest tail of `url` that contains `needle`, growing the window until
// it turns up (or the whole file has been read).
//
// A fixed 64 KB tail was wrong, and shipped broken in v1.2.3. Codex writes a
// `rate_limits` line on each API turn, but a session keeps appending afterwards —
// tool output, local events, a long final assistant message — so "the last few KB"
// is not a safe bet. A real 766 KB log had its last `rate_limits` 87 KB from EOF:
// outside the window, so Codex reported "No rate-limit data yet." while the data sat
// right there in the file.
//
// Growing keeps the optimisation's point. The common case — an active session whose
// last turn is near the end — still costs a single 64 KB read; only logs that bury
// the line pay for more, and the ceiling is the file itself.
func tailContaining(_ url: URL, needle: String,
                    from start: Int = 1 << 16, upTo limit: Int = 1 << 24) -> String? {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
        .flatMap { $0[.size] as? Int } ?? 0
    guard size > 0 else { return nil }
    var window = min(start, size)
    while true {
        guard let text = tailOfFile(url, bytes: window) else { return nil }
        // Found it, or we've already read everything there is to read. Returning the
        // text either way lets the caller distinguish "no rate-limit data in this
        // session" from "no session at all" — the two report differently.
        if text.contains(needle) || window >= size || window >= limit { return text }
        window = min(window * 4, min(size, limit))
    }
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

func _fetchOpenCode() async -> Tool {
    var tool = Tool(name: "OpenCode", logoKey: "opencode", accent: OPENCODE_ACCENT,
                    metrics: [], subtitle: "pay-as-you-go", failed: nil)

    let db = Paths.opencodeDB
    guard FileManager.default.fileExists(atPath: db) else {
        tool.failed = "No OpenCode database."
        return tool
    }
    let weekAgoMs = Int64((Date().timeIntervalSince1970 - 7 * 86400) * 1000)
    let query = """
    SELECT ROUND(SUM(json_extract(data,'$.cost')),2),
           SUM(COALESCE(json_extract(data,'$.tokens.input'),0)
             + COALESCE(json_extract(data,'$.tokens.output'),0)
             + COALESCE(json_extract(data,'$.tokens.cache.read'),0)
             + COALESCE(json_extract(data,'$.tokens.cache.write'),0))
    FROM message WHERE time_created > ?;
    """
    guard let row = sqliteFirstRow(dbPath: db, sql: query, params: [weekAgoMs]) else {
        tool.failed = "Query failed."
        return tool
    }
    // Both columns are NULL when no messages fall in the window — that's zero spend,
    // not a failure.
    let cost = row.first.flatMap { $0 } ?? 0
    let toks = row.count > 1 ? (row[1] ?? 0) : 0
    tool.metrics.append(Metric(label: "This week", percent: nil,
                               detail: String(format: "$%.2f · %@ tok", cost, humanTokens(toks))))
    return tool
}

// MARK: - Live fetcher

// Production fetcher. Just delegates to the underscored functions above; the rename
// avoids an `ambiguous use` between the free function and the protocol method when
// both are visible to `LiveFetcher` (Swift's name resolution looks at both).
struct LiveFetcher: UsageFetcher {
    func fetchClaude() async -> Tool { await _fetchClaude() }
    func fetchCodex() async -> Tool { await _fetchCodex() }
    func fetchOpenCode() async -> Tool { await _fetchOpenCode() }
}
