import Foundation

// Tests for the hard request gate in UsageStore.refresh(). The gate is the
// difference between a steady, never-rate-limited app and one that 429s itself
// into a multi-minute cooldown. These tests pin `now()` and override timing
// thresholds so the logic can be exercised without any real wall-clock waits.
@MainActor
struct ThrottleTests {

    static func run() async {
        await firstRefreshRuns()
        await withinMinSpacingDefers()
        await canFetchNowMatchesTheGate()
        await rateLimitedAppliesCooldown()
        await rateLimitedEscalates()
        await successResetsStrikes()
        await localToolsDoNotWaitOnClaude()
        await localRefreshPolitenessCoalesces()
        await requestRefreshHonoursBaseGap()
        await non429FailureDoesNotCooldown()
        await lastGoodFallbackOnFailure()
        await fetchOutcomeFlagOutlivesLastGoodFallback()
    }

    // The happy path: nothing in flight, plenty of time since last fetch — refresh
    // actually runs and the fetcher is called.
    static func firstRefreshRuns() async {
        let fetcher = MockFetcher()
        let store = makeStore(fetcher: fetcher)
        store.minSpacing = 0      // disable the floor for this test
        await store.refresh()
        expectEqual(fetcher.claudeCalls, 1)
        expectEqual(fetcher.codexCalls, 1)
        expectEqual(fetcher.opencodeCalls, 1)
        expectNotNil(store.lastUpdated)
        expectEqual(store.loading, false)
    }

    // After a fetch, the gate reserves a slot so a second refresh inside
    // minSpacing is deferred, not sent.
    static func withinMinSpacingDefers() async {
        let fetcher = MockFetcher()
        let store = makeStore(fetcher: fetcher)
        store.minSpacing = 30
        await store.refresh()
        expectEqual(fetcher.claudeCalls, 1)
        // Second refresh inside the window must NOT call the fetcher again.
        await store.refresh()
        expectEqual(fetcher.claudeCalls, 1, "second fetch inside minSpacing must be deferred")
    }

    // `canFetchNow` has to agree with the gate it describes — the refresh button reads it
    // to decide whether a tap will produce a spin or go straight to the checkmark, so a
    // disagreement would show the wrong animation for what actually happened.
    static func canFetchNowMatchesTheGate() async {
        let fetcher = MockFetcher()
        let store = makeStore(fetcher: fetcher)
        store.minSpacing = 30
        let t0 = Date()
        store.now = { t0 }
        expectEqual(store.canFetchNow, true, "nothing sent yet — a tap should fetch")
        await store.refresh()
        expectEqual(store.canFetchNow, false, "inside minSpacing a tap sends nothing")
        store.now = { t0.addingTimeInterval(31) }
        expectEqual(store.canFetchNow, true, "past minSpacing a tap fetches again")
    }

    // A 429 increments rlStrikes and sets nextAllowed to now + the matching
    // cooldown. The next request is deferred past that point.
    static func rateLimitedAppliesCooldown() async {
        let store = makeStore()
        store.minSpacing = 0
        store.coolDowns = [10, 20, 40]              // short, predictable for the test
        let t0 = Date()
        store.now = { t0 }
        // Force a 429 by injecting a tool whose failure message contains the trigger.
        store.fetcher = MockFetcher(claude: failingTool("Claude", logo: "claude",
                                                         accent: CLAUDE_ACCENT,
                                                         message: "Rate limited — retry shortly."))
        await store.refresh()
        expectEqual(store.rlStrikes, 1)
        // nextAllowed is now at least t0 + 10 (the first cooldown).
        expect(store.nextAllowed >= t0.addingTimeInterval(10),
               "nextAllowed should be at least 10s past the 429 time")
    }

    // Repeated 429s escalate the cooldown. The 5th strike is the cap.
    static func rateLimitedEscalates() async {
        let store = makeStore()
        store.minSpacing = 0
        store.coolDowns = [10, 20, 40, 80, 160]
        let t0 = Date()
        store.fetcher = MockFetcher(claude: failingTool("Claude", logo: "claude",
                                                         accent: CLAUDE_ACCENT,
                                                         message: "Rate limited — retry shortly."))
        for i in 1...5 {
            // Advance `now` past the last cooldown so refresh is actually allowed
            // to run (otherwise it just queues a flush).
            store.now = { t0.addingTimeInterval(Double(i) * 200) }
            await store.refresh()
            expectEqual(store.rlStrikes, min(i, store.coolDowns.count))
        }
        // After 5 strikes, the cap kicks in — next attempt shouldn't push rlStrikes
        // beyond coolDowns.count.
        let capped = store.rlStrikes
        store.now = { t0.addingTimeInterval(2000) }
        await store.refresh()
        expectEqual(store.rlStrikes, capped, "strikes should not exceed coolDowns.count")
    }

    // A success after a 429 clears the strike counter so the next 429 starts
    // the cooldown over from the bottom.
    static func successResetsStrikes() async {
        let store = makeStore()
        store.minSpacing = 0
        store.coolDowns = [10, 20, 40, 80, 160]
        let t0 = Date()
        store.now = { t0 }
        // 429…
        store.fetcher = MockFetcher(claude: failingTool("Claude", logo: "claude",
                                                         accent: CLAUDE_ACCENT,
                                                         message: "Rate limited — retry shortly."))
        await store.refresh()
        expectEqual(store.rlStrikes, 1)
        // …then success, after enough time has passed.
        store.now = { t0.addingTimeInterval(500) }
        store.fetcher = MockFetcher()
        await store.refresh()
        expectEqual(store.rlStrikes, 0, "a successful fetch should clear the strike counter")
    }

    // Local tools (Codex + OpenCode) have their own much shorter gap; they must
    // not wait on Claude's 5-minute politeness. This is the regression that
    // landed as the most recent commit on main.
    static func localToolsDoNotWaitOnClaude() async {
        let fetcher = MockFetcher()
        let store = makeStore(fetcher: fetcher)
        store.localGap = 0                          // disable local politeness
        store.baseGap = 300                         // keep Claude's gap on
        await store.refresh()                       // Claude goes first
        expectEqual(fetcher.claudeCalls, 1)
        expectEqual(fetcher.codexCalls, 1)
        expectEqual(fetcher.opencodeCalls, 1)
        // A local-only refresh should fetch Codex and OpenCode, not Claude.
        // refreshLocalTools() spawns a Task and returns; wait for the spawned
        // task to actually reach the fetcher.
        store.refreshLocalTools()
        await awaitFetch(fetcher, codex: 2, opencode: 2)
        expectEqual(fetcher.claudeCalls, 1, "local refresh must not touch Claude")
        expectEqual(fetcher.codexCalls, 2)
        expectEqual(fetcher.opencodeCalls, 2)
    }

    // A burst of local reads is throttled to one per `localGap`. Once the first
    // read has set lastLocalAt, subsequent rapid calls within the window get
    // coalesced into a single pending read.
    static func localRefreshPolitenessCoalesces() async {
        let fetcher = MockFetcher()
        let store = makeStore(fetcher: fetcher)
        store.localGap = 60
        // First call: spawns a Task, fetcher is called, lastLocalAt is set.
        store.refreshLocalTools()
        await awaitFetch(fetcher, codex: 1)
        let firstWave = fetcher.codexCalls
        // Now fire three more in rapid succession. lastLocalAt is set, so each
        // is within the localGap; the second and third should be coalesced into
        // the pendingLocal deferred task, not fire new reads.
        store.refreshLocalTools()
        store.refreshLocalTools()
        store.refreshLocalTools()
        // Give the Tasks a beat to do (or not do) work.
        try? await Task.sleep(nanoseconds: 200_000_000)
        expectEqual(fetcher.codexCalls, firstWave,
                    "rapid local refreshes after the first read should coalesce")
    }

    // requestRefresh enforces baseGap; the second call within the window is a
    // no-op (not a fetch, not even a deferred one).
    static func requestRefreshHonoursBaseGap() async {
        let fetcher = MockFetcher()
        let store = makeStore(fetcher: fetcher)
        store.minSpacing = 0
        store.baseGap = 300
        await store.refresh()                       // first fetch, sets lastRefreshAt
        store.requestRefresh()
        store.requestRefresh()
        // No fetcher activity should have been triggered by the politeness check.
        expectEqual(fetcher.claudeCalls, 1)
    }

    // A failed read on Claude (e.g. 500) is NOT a rate limit — rlStrikes must
    // stay at 0 so the next attempt doesn't apply a cooldown.
    static func non429FailureDoesNotCooldown() async {
        let store = makeStore()
        store.minSpacing = 5
        store.coolDowns = [45, 120, 300]
        store.fetcher = MockFetcher(claude: failingTool("Claude", logo: "claude",
                                                         accent: CLAUDE_ACCENT,
                                                         message: "Offline."))
        await store.refresh()
        expectEqual(store.rlStrikes, 0)
        // nextAllowed should be `lastRefreshAt + minSpacing` (the regular floor), not
        // the 45 s cooldown.
        let delta = store.nextAllowed.timeIntervalSince(store.lastRefreshAt ?? .distantPast)
        expectApprox(delta, store.minSpacing,
                     "nextAllowed should advance by minSpacing, not by the 429 cooldown")
    }

    // A successful read also stashes the tool in lastGood so a transient failure
    // doesn't blank the row. (A 200 with parsed metrics is success; a failure
    // with metrics falls back to lastGood.)
    static func lastGoodFallbackOnFailure() async {
        let store = makeStore()
        store.minSpacing = 0
        let good = tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                        label: "Weekly", percent: 42)
        // First fetch: success
        store.fetcher = MockFetcher(claude: good)
        await store.refresh()
        // Second fetch: failure for Claude, success for the rest
        store.fetcher = MockFetcher(claude: failingTool("Claude", logo: "claude",
                                                         accent: CLAUDE_ACCENT,
                                                         message: "Offline."),
                                     codex: good, opencode: good)
        await store.refresh()
        let claude = store.tools.first(where: { $0.name == "Claude" })
        expectNotNil(claude)
        expectEqual(claude?.metrics.first?.percent ?? 0, 42,
                    "failed read should fall back to last good reading")
        expectNil(claude?.failed, "last-good fallback should clear the failure state")
    }

    // `lastFetchFailed` is the refresh button's only source for its outcome morph, and
    // it has to survive exactly the case above: the last-good fallback scrubs `failed`
    // off the tool, so reading the flag is the only way to know the fetch went wrong.
    static func fetchOutcomeFlagOutlivesLastGoodFallback() async {
        let store = makeStore()
        store.minSpacing = 0
        let good = tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                        label: "Weekly", percent: 42)
        store.fetcher = MockFetcher(claude: good, codex: good, opencode: good)
        await store.refresh()
        expectEqual(store.lastFetchFailed, false, "a clean fetch should not report failure")

        store.fetcher = MockFetcher(claude: failingTool("Claude", logo: "claude",
                                                         accent: CLAUDE_ACCENT,
                                                         message: "Offline."),
                                     codex: good, opencode: good)
        await store.refresh()
        expectEqual(store.lastFetchFailed, true,
                    "a failed provider should set the flag even though tools hides it")
        expectNil(store.tools.first(where: { $0.name == "Claude" })?.failed,
                  "…and the flag is needed precisely because the tool looks fine")

        // The flag is about the *last* fetch only — a clean one clears it again.
        store.fetcher = MockFetcher(claude: good, codex: good, opencode: good)
        await store.refresh()
        expectEqual(store.lastFetchFailed, false, "a later clean fetch should clear the flag")
    }
}
