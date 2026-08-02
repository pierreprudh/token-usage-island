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

// MARK: - Codex (last rate_limits from newest session log)

func _fetchCodex() async -> Tool {
    var tool = Tool(name: "Codex", logoKey: "codex", accent: CODEX_ACCENT, metrics: [], subtitle: nil, failed: nil)

    guard let fileURL = newestCodexSession(),
          let content = tailContaining(fileURL, needle: "rate_limits") else {
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
        // `slot` disambiguates the primary/secondary pair in the milestone bucket key
        // when both happen to share a label (e.g. two weekly windows). The user-facing
        // label is unchanged.
        tool.metrics.append(Metric(label: label, percent: used, detail: detail, slot: "primary"))
    }
    if let secondary = rl["secondary"] as? [String: Any],
       let used = secondary["used_percent"] as? Double {
        var detail = ""
        if let resetEpoch = secondary["resets_at"] as? Double {
            detail = resetDetail(Date(timeIntervalSince1970: resetEpoch))
        }
        // Name it by its window like `primary` does — "Secondary" told the milestone lip
        // nothing, so a Codex weekly crossing showed a bare "20%" with no period tag.
        let window = secondary["window_minutes"] as? Double ?? 0
        let label = window >= 10080 ? "Weekly" : (window >= 300 ? "Session" : "Secondary")
        tool.metrics.append(Metric(label: label, percent: used, detail: detail, slot: "secondary"))
    }
    if tool.metrics.isEmpty { tool.failed = "No rate-limit data yet." }
    return tool
}

// Find newest .jsonl under the Codex sessions dir (sync — enumerator isn't async-safe).
func newestCodexSession() -> URL? {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: URL(fileURLWithPath: Paths.codexSessions),
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
