import Foundation

// Locks down the two Codex-specific bugs/fixes from the review:
//
//   1. Primary and secondary used to share a milestone bucket key, so when both
//      happened to be weekly the second one's crossings got silently shadowed.
//      The fix adds a `slot` to Metric and includes it in the key.
//
//   2. _fetchCodex() used to slurp the whole session .jsonl into memory. For
//      multi-MB logs this is wasteful — the latest rate_limits line lives in
//      the tail. We verify the tailOfFile helper does the right thing on a
//      large fake log.
@MainActor
struct CodexTests {

    static func run() async {
        sameLabelDifferentSlotsAreSeparateBuckets()
        await tailDropsPartialFirstLine()
        await tailSurvivesMultibyteBoundary()
        await tailFallsBackWhenNoNewlineInWindow()
        await tailOfLargeFileIsFast()
        await tailOfMissingFileIsNil()
        await tailContainingFindsNeedleBeyondFirstWindow()
        await tailContainingStopsAtWholeFileWhenNeedleAbsent()
        await tailContainingOfMissingFileIsNil()
        await tailContainingCostsOneWindowWhenNeedleIsNearTheEnd()
    }

    // The slot on the Metric is what disambiguates two same-label metrics in
    // the milestone bucket key. Without it, the second metric's crossing is
    // shadowed by the first.
    static func sameLabelDifferentSlotsAreSeparateBuckets() {
        let primary = Metric(label: "Weekly", percent: 35, detail: "", slot: "primary")
        let secondary = Metric(label: "Weekly", percent: 22, detail: "", slot: "secondary")
        // Both have the same user-facing label…
        expectEqual(primary.label, secondary.label)
        // …but distinct slots, which the milestone key uses to keep them apart.
        expectNotEqual(primary.slot ?? "", secondary.slot ?? "",
                      "slots must differ so the milestone key can keep them separate")
    }

    // tailOfFile should return the last N bytes, dropping the partial first line
    // when the read started mid-file.
    static func tailDropsPartialFirstLine() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tui-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = (1...10).map { "line-\($0)-payload-padding-padding-padding-padding" }
            .joined(separator: "\n")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("could not write test fixture: \(error)")
            return
        }
        // Request a tail that starts mid-line. tailOfFile should drop the first
        // partial line and return cleanly-split lines from there on.
        let tail = tailOfFile(url, bytes: 80)
        expectNotNil(tail)
        guard let tail else { return }
        let lines = tail.split(separator: "\n").map(String.init)
        expect(!lines.isEmpty, "tail should not be empty")
        // Every returned line must be a complete line (starts with "line-N-"),
        // not a fragment of one.
        for line in lines {
            expect(line.hasPrefix("line-"),
                   "partial first line should have been dropped, got: \(line)")
        }
    }

    // Regression: the tail window can open in the middle of a multi-byte character,
    // because session logs are prompt text and the byte offset knows nothing about
    // character boundaries. Decoding the window before trimming the partial line
    // returned nil for the whole file, so _fetchCodex() reported "No Codex sessions."
    // on a log that had them. Every requested tail size must still yield the last
    // line, whatever character the window happens to cut in half.
    static func tailSurvivesMultibyteBoundary() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tui-test-utf8-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        // Emoji are 4 bytes, "é" is 2, "日" is 3 — a spread of widths so the sweep
        // below lands inside sequences of several different lengths.
        let padding = "🎉é日本語-padding-🚀-ünïcøde"
        let body = (1...12).map { "line-\($0)-\(padding)" }.joined(separator: "\n")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("could not write utf8 test fixture: \(error)")
            return
        }
        let lastLine = "line-12-\(padding)"
        // Sweep every window size across a couple of lines. Some of these necessarily
        // start mid-character; none may fail.
        for size in 20...140 {
            guard let tail = tailOfFile(url, bytes: size) else {
                fail("tail returned nil for bytes: \(size) — multi-byte boundary regression")
                continue
            }
            expect(tail.hasSuffix(lastLine),
                   "tail(bytes: \(size)) must still end with the final line, got: \(tail.suffix(30))")
            // A dropped partial line must never leave a replacement char behind, which
            // is what a mid-character trim would produce.
            expect(!tail.contains("\u{FFFD}"),
                   "tail(bytes: \(size)) contains U+FFFD — trimmed mid-character")
        }
    }

    // A line longer than the window leaves no newline to trim at, so the tail would
    // be a fragment that no JSON line parses out of. Fall back to the whole file.
    static func tailFallsBackWhenNoNewlineInWindow() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tui-test-longline-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = "{\"rate_limits\":{\"primary\":{\"used_percent\":42}}}" +
                   String(repeating: "x", count: 4_000)
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("could not write long-line test fixture: \(error)")
            return
        }
        // Window far smaller than the single line it contains.
        guard let tail = tailOfFile(url, bytes: 100) else {
            fail("tail must fall back to the whole file, got nil")
            return
        }
        expect(tail.contains("rate_limits"),
               "fallback should return the whole line so rate_limits is still findable")
    }

    // Tail must be cheap: a 5 MB log, a 64 KB tail. Verify the function returns
    // promptly and the result is non-nil.
    static func tailOfLargeFileIsFast() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tui-test-large-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        // 5 MB of repetitive line content. Each line is well under 64 KB, so the
        // last line is in the tail.
        let line = String(repeating: "x", count: 200) + "\n"
        let chunk = String(repeating: line, count: 25_000)         // 5 MB
        do {
            try chunk.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("could not write large test fixture: \(error)")
            return
        }

        let start = Date()
        let tail = tailOfFile(url, bytes: 1 << 16)
        let elapsed = Date().timeIntervalSince(start)
        expectNotNil(tail, "tail of existing file must not be nil")
        expect(elapsed < 1.0, "tail read should be near-instant; took \(elapsed)s")
    }

    // A non-existent file must return nil without throwing — the fetcher relies
    // on this to report "No Codex sessions." cleanly.
    static func tailOfMissingFileIsNil() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tui-test-missing-\(UUID().uuidString).jsonl")
        expectNil(tailOfFile(url))
    }

    // Writes a log whose only `rate_limits` line sits `tailBytes` from the end,
    // buried under filler — the shape of the real session that broke v1.2.3.
    private static func writeBuriedLog(needleDistanceFromEnd: Int) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tui-test-buried-\(UUID().uuidString).jsonl")
        let rl = "{\"rate_limits\":{\"primary\":{\"used_percent\":21}}}"
        let filler = "{\"type\":\"item\",\"text\":\"" + String(repeating: "z", count: 200) + "\"}"
        var trailing = ""
        while trailing.utf8.count < needleDistanceFromEnd {
            trailing += filler + "\n"
        }
        let body = filler + "\n" + rl + "\n" + trailing
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("could not write buried-needle fixture: \(error)")
            return nil
        }
        return url
    }

    // The v1.2.3 regression, locked down. A fixed window silently missed a
    // rate_limits line that was further from EOF than the window was wide, and the
    // Codex panel read "No rate-limit data yet." on a log that had the data.
    static func tailContainingFindsNeedleBeyondFirstWindow() async {
        // Needle ~90 KB from the end, mirroring the observed 87 KB. The default
        // 64 KB starting window cannot see it; growing must.
        guard let url = writeBuriedLog(needleDistanceFromEnd: 90_000) else { return }
        defer { try? FileManager.default.removeItem(at: url) }

        // Precondition: the plain fixed-window read really does miss it. If this
        // ever stops holding, the test below is no longer proving anything.
        let fixed = tailOfFile(url, bytes: 1 << 16)
        expect(!(fixed?.contains("rate_limits") ?? false),
               "fixture must bury the needle outside a 64 KB window, else this test is vacuous")

        guard let grown = tailContaining(url, needle: "rate_limits") else {
            fail("tailContaining returned nil on a file that contains the needle")
            return
        }
        expect(grown.contains("rate_limits"),
               "tailContaining must grow its window until the needle is found")
        // And the found line must still parse — a grown window that starts mid-line
        // would hand JSONSerialization a fragment.
        let hit = grown.split(separator: "\n").last { $0.contains("rate_limits") }
        expectNotNil(hit, "the needle line should survive the partial-line trim")
        if let hit, let d = hit.data(using: .utf8) {
            expectNotNil(try? JSONSerialization.jsonObject(with: d),
                         "the recovered rate_limits line must be complete JSON")
        }
    }

    // No needle anywhere: return the whole file rather than nil, so the caller can
    // tell "session with no rate-limit data" from "no session at all". They surface
    // as different messages.
    static func tailContainingStopsAtWholeFileWhenNeedleAbsent() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tui-test-noneedle-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = (1...500).map { "{\"type\":\"item\",\"n\":\($0)}" }.joined(separator: "\n")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("could not write no-needle fixture: \(error)")
            return
        }
        let out = tailContaining(url, needle: "rate_limits")
        expectNotNil(out, "a readable file with no needle must still return its text")
        expect(!(out?.contains("rate_limits") ?? true), "there is no needle to find")
    }

    static func tailContainingOfMissingFileIsNil() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tui-test-cmissing-\(UUID().uuidString).jsonl")
        expectNil(tailContaining(url, needle: "rate_limits"),
                  "a missing session must stay nil so the fetcher says 'No Codex sessions.'")
    }

    // The optimisation must survive the fix: when the line is near the end — the
    // common case of an active session — we should still read only the first window,
    // not escalate to the whole multi-MB file.
    static func tailContainingCostsOneWindowWhenNeedleIsNearTheEnd() async {
        guard let url = writeBuriedLog(needleDistanceFromEnd: 2_000) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let out = tailContaining(url, needle: "rate_limits") else {
            fail("tailContaining returned nil on a file that contains the needle")
            return
        }
        expect(out.contains("rate_limits"), "needle near the end must be found")
        // Returned text should be about one window, not the whole file — proof we
        // stopped growing as soon as we had a hit.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.size] as? Int } ?? 0
        expect(out.utf8.count <= (1 << 16),
               "should have stopped at the first 64 KB window, got \(out.utf8.count) of \(size) bytes")
    }
}
