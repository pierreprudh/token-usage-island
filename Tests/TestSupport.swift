import Foundation
import SwiftUI

// A fetcher that returns canned Tool values and records each call. Tests inject this
// into UsageStore so refresh() exercises the throttle/queue logic without touching
// the real Keychain, SQLite, or JSONL.
@MainActor
final class MockFetcher: UsageFetcher {
    var claude: Tool
    var codex: Tool
    var opencode: Tool
    var claudeCalls = 0
    var codexCalls = 0
    var opencodeCalls = 0
    // Optional per-call delay — lets tests check that gates are honoured even when
    // a fetch is in flight.
    var fetchDelayMs: UInt64 = 0

    init(claude: Tool? = nil, codex: Tool? = nil, opencode: Tool? = nil) {
        self.claude = claude ?? Tool(name: "Claude", logoKey: "claude", accent: CLAUDE_ACCENT,
                                    metrics: [], subtitle: nil, failed: nil)
        self.codex = codex ?? Tool(name: "Codex", logoKey: "codex", accent: CODEX_ACCENT,
                                   metrics: [], subtitle: nil, failed: nil)
        self.opencode = opencode ?? Tool(name: "OpenCode", logoKey: "opencode", accent: OPENCODE_ACCENT,
                                         metrics: [], subtitle: nil, failed: nil)
    }

    func fetchClaude() async -> Tool {
        claudeCalls += 1
        if fetchDelayMs > 0 { try? await Task.sleep(nanoseconds: fetchDelayMs * 1_000_000) }
        return claude
    }
    func fetchCodex() async -> Tool {
        codexCalls += 1
        if fetchDelayMs > 0 { try? await Task.sleep(nanoseconds: fetchDelayMs * 1_000_000) }
        return codex
    }
    func fetchOpenCode() async -> Tool {
        opencodeCalls += 1
        if fetchDelayMs > 0 { try? await Task.sleep(nanoseconds: fetchDelayMs * 1_000_000) }
        return opencode
    }
}

// Build a UsageStore with deterministic timing, a fresh lastBucket, and no in-flight
// throttle. The default initialiser reads from UserDefaults (tool order) and leaves
// nextAllowed at .distantPast, which is what we want for the happy path. Tests that
// exercise the gate override nextAllowed directly.
@MainActor
func makeStore(fetcher: MockFetcher? = nil, now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> UsageStore {
    let store = UsageStore()
    store.now = { now }
    if let fetcher { store.fetcher = fetcher }
    // Make sure persisted order from a previous test run doesn't shuffle our tools.
    store.persistOrder()
    return store
}

// Tool with a single percent metric.
func tool(_ name: String, logo: String, accent: Color, label: String,
           percent: Double, slot: String? = nil) -> Tool {
    Tool(name: name, logoKey: logo, accent: accent,
         metrics: [Metric(label: label, percent: percent, detail: "", slot: slot)],
         subtitle: nil, failed: nil)
}

// Tool with an explicit failure message (so absorb() falls back to lastGood).
func failingTool(_ name: String, logo: String, accent: Color, message: String) -> Tool {
    Tool(name: name, logoKey: logo, accent: accent,
         metrics: [], subtitle: nil, failed: message)
}

// Wait for `store.milestone` to become non-nil. The dequeue is dispatched onto a
// Task, so @Published may lag the call to detectMilestone() by a runloop tick.
@MainActor
func awaitMilestone(_ store: UsageStore, timeout: TimeInterval = 1.0) async -> MilestoneEvent? {
    let deadline = Date().addingTimeInterval(timeout)
    while store.milestone == nil, Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return store.milestone
}

// Wait for `store.milestone` to become nil again (i.e. the queue is drained).
@MainActor
func awaitMilestoneDrained(_ store: UsageStore, timeout: TimeInterval = 1.0) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while store.milestone != nil, Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return store.milestone == nil
}

// refreshLocalTools() and requestRefresh() are not async — they spawn a Task and
// return. Wait for the spawned task to actually reach the fetcher before checking
// the call count. Polls the counts with a short sleep until they reach `atLeast`
// or the timeout fires.
@MainActor
func awaitFetch(_ fetcher: MockFetcher,
                claude: Int? = nil, codex: Int? = nil, opencode: Int? = nil,
                timeout: TimeInterval = 2.0) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let ok =
            (claude    == nil || fetcher.claudeCalls    >= claude!) &&
            (codex     == nil || fetcher.codexCalls     >= codex!) &&
            (opencode  == nil || fetcher.opencodeCalls  >= opencode!)
        if ok { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
