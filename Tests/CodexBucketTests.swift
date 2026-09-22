import Foundation

// Codex 0.155 started reporting more than one rate-limit bucket in a session. The
// plan allowance is `limit_id: "codex"`; once Codex Desktop routes a session onto
// "Luna Reserve", every later line is `limit_id: "base_model_inference"` with
// `limit_name: "gpt-reserve"`, a single weekly window and a null secondary. Taking
// "the last rate_limits line" then showed the reserve as the plan: a bare "Weekly 0%"
// with the Session row gone. These fixtures are cut from the real 21 Sept 2026 log.
@MainActor
struct CodexBucketTests {

    static func run() async {
        await planBucketWinsOverReserveInTheSameSession()
        await planLineDeeperThanTheFirstTailWindowIsStillFound()
        await sessionBornOnTheReserveFallsBackToAnOlderSession()
        await legacyLinesWithoutLimitIdAreThePlan()
        await passedResetReadsAsZeroNotAsTheStaleValue()
        await freshReadingCarriesNoAsOfSuffix()
        await bucketWithNullWindowsIsIgnored()
    }

    // Times: `now` is 22 Sept 2026 11:43 UTC — a day after the plan line, while the
    // weekly window is still open and the 5 h window has long rolled over.
    static let now = Date(timeIntervalSince1970: 1_790_077_380)

    static let planLine = """
    {"timestamp":"2026-09-21T15:45:07.293Z","ordinal":381,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":70.0,"window_minutes":300,"resets_at":1790014357},"secondary":{"used_percent":11.0,"window_minutes":10080,"resets_at":1790601157},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":null}}}}
    """
    static func reserveLine(at ts: String = "2026-09-22T09:34:28.669Z", resetsAt: Int = 1_790_674_448) -> String {
        """
        {"timestamp":"\(ts)","ordinal":1200,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1},"rate_limits":{"limit_id":"base_model_inference","limit_name":"gpt-reserve","primary":{"used_percent":0.0,"window_minutes":10080,"resets_at":\(resetsAt)},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":null}}}}
        """
    }
    static let premiumLine = """
    {"timestamp":"2026-09-21T21:01:31.464Z","ordinal":700,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1},"rate_limits":{"limit_id":"premium","limit_name":null,"primary":null,"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":null}}}}
    """
    static let legacyLine = """
    {"timestamp":"2026-09-16T21:30:29.483Z","type":"event_msg","payload":{"type":"token_count","info":{"rate_limits":{"primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1790100000},"secondary":{"used_percent":91.0,"window_minutes":10080,"resets_at":1790601157},"plan_type":"plus"}}}}
    """
    static let filler = "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"text\":\"" + String(repeating: "z", count: 300) + "\"}}"

    // A fake ~/.codex/sessions: files under a dated tree, with the mtimes the
    // fetcher orders by. Returns the root; caller removes it.
    static func sessionsDir(files: [(name: String, lines: [String], mtime: Date)]) -> URL? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tui-codex-\(UUID().uuidString)")
        do {
            for f in files {
                let dir = root.appendingPathComponent("2026/09/\(f.name.prefix(2))")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("rollout-\(f.name).jsonl")
                try (f.lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.modificationDate: f.mtime], ofItemAtPath: url.path)
            }
        } catch {
            fail("could not build sessions fixture: \(error)")
            return nil
        }
        return root
    }

    static func metric(_ tool: Tool, _ slot: String) -> Metric? { tool.metrics.first { $0.slot == slot } }

    // The shape of the real log: plan lines, then reserve lines until EOF.
    static func planBucketWinsOverReserveInTheSameSession() async {
        guard let root = sessionsDir(files: [
            ("21", [filler, planLine, filler, premiumLine, reserveLine(at: "2026-09-22T09:08:16.687Z"), reserveLine()], now),
        ]) else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = await _fetchCodex(sessionsDir: root.path, now: now)

        expectNil(tool.failed, "a session with a plan line must not fail: \(tool.failed ?? "")")
        expectEqual(tool.subtitle, "Plus plan")
        // 5 h window: reset at 17:32 UTC on the 21st, so by `now` it has rolled over.
        expectEqual(metric(tool, "primary")?.label, "Session")
        expectEqual(metric(tool, "primary")?.percent, 0)
        expectEqual(metric(tool, "primary")?.detail, "Reset since last run")
        // Weekly window is still open: keep the value, but say when it was read.
        expectEqual(metric(tool, "secondary")?.label, "Weekly")
        expectEqual(metric(tool, "secondary")?.percent, 11)
        expect(metric(tool, "secondary")?.detail.hasPrefix("Resets ") ?? false,
               "open window keeps its reset time up front, got: \(metric(tool, "secondary")?.detail ?? "nil")")
        expect(metric(tool, "secondary")?.detail.contains(" · as of ") ?? false,
               "a day-old reading must say so, got: \(metric(tool, "secondary")?.detail ?? "nil")")
        // The reserve is its own row, never the plan's.
        expectEqual(metric(tool, "reserve")?.label, "Reserve")
        expectEqual(metric(tool, "reserve")?.percent, 0)
        expectEqual(tool.metrics.count, 3)
    }

    // The real 09/21 log had its last plan line 2.5 MB from EOF, under reserve lines
    // and tool output. The first 64 KB tail sees only reserve lines; the fetcher must
    // grow towards the plan tag rather than declare the session plan-less.
    static func planLineDeeperThanTheFirstTailWindowIsStillFound() async {
        var lines = [planLine]
        while lines.joined(separator: "\n").utf8.count < 300_000 { lines.append(filler) }
        lines.append(reserveLine())
        guard let root = sessionsDir(files: [("21", lines, now)]) else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = await _fetchCodex(sessionsDir: root.path, now: now)

        expectEqual(metric(tool, "secondary")?.percent, 11,
                    "plan line buried under 300 KB of reserve-era log must still be read")
        expectEqual(metric(tool, "reserve")?.percent, 0)
    }

    // A session that was on the reserve from its first turn has no plan line at all.
    // The plan reading then comes from the newest older session that has one.
    static func sessionBornOnTheReserveFallsBackToAnOlderSession() async {
        guard let root = sessionsDir(files: [
            ("22", [filler, reserveLine(), reserveLine()], now),
            ("21", [filler, planLine, filler], now.addingTimeInterval(-86_400)),
            ("13", [legacyLine], now.addingTimeInterval(-7 * 86_400)),
        ]) else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = await _fetchCodex(sessionsDir: root.path, now: now)

        // From the 21st, not the 13th: newest session with a plan line wins.
        expectEqual(metric(tool, "secondary")?.percent, 11)
        expectEqual(metric(tool, "reserve")?.label, "Reserve", "the current session's reserve still shows")
        expectEqual(tool.metrics.count, 3)
    }

    // Logs written before `limit_id` existed carry only the plan bucket.
    static func legacyLinesWithoutLimitIdAreThePlan() async {
        let seen = Date(timeIntervalSince1970: 1_790_040_000)   // 22 Sept 01:20 UTC
        guard let root = sessionsDir(files: [("16", [filler, legacyLine], seen)]) else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = await _fetchCodex(sessionsDir: root.path, now: seen.addingTimeInterval(60))

        expectNil(tool.failed)
        expectEqual(metric(tool, "primary")?.label, "Session")
        expectEqual(metric(tool, "primary")?.percent, 3)
        expectEqual(metric(tool, "secondary")?.percent, 91)
        expectNil(metric(tool, "reserve"), "no reserve row without a reserve line")
    }

    // The 5 h window rolled over after the reading: its 70% is history, not the
    // current state. Showing it as current would send a false milestone.
    static func passedResetReadsAsZeroNotAsTheStaleValue() async {
        let (pct, detail) = codexWindowReading(used: 70, resetsAt: 1_790_014_357,
                                               seenAt: parseISO("2026-09-21T15:45:07.293Z"), now: now)
        expectEqual(pct, 0)
        expectEqual(detail, "Reset since last run")
        // But a reset that passed *before* the reading is the server's business, not
        // ours: the value was already read with that window state.
        let (pct2, detail2) = codexWindowReading(used: 70, resetsAt: 1_790_014_357,
                                                 seenAt: now, now: now)
        expectEqual(pct2, 70)
        expectEqual(detail2, "resetting…")
    }

    // A reading from the last hour is current: no suffix, exactly what it showed before.
    static func freshReadingCarriesNoAsOfSuffix() async {
        let (pct, detail) = codexWindowReading(used: 11, resetsAt: 1_790_601_157,
                                               seenAt: now.addingTimeInterval(-600), now: now)
        expectEqual(pct, 11)
        expect(detail.hasPrefix("Resets ") && !detail.contains("as of"),
               "fresh reading must read exactly as before, got: \(detail)")
    }

    // `limit_id: "premium"` arrives with null windows: nothing to show, and it must
    // not displace the reserve row that has one.
    static func bucketWithNullWindowsIsIgnored() async {
        guard let root = sessionsDir(files: [
            ("21", [planLine, reserveLine(), premiumLine], now),
        ]) else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = await _fetchCodex(sessionsDir: root.path, now: now)

        expectEqual(metric(tool, "reserve")?.label, "Reserve")
        expectEqual(tool.metrics.count, 3)
    }
}
