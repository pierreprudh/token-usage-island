import Foundation
import Combine

// The app's reactive layer: throttling, the milestone queue, and the last-good
// fallback. Unlike the rest of Sources/Core this still needs Combine for
// ObservableObject, so it is Apple-only for now — the `usage status` CLI does not
// build it, which is why the CLI can prove the fetch layer is Foundation-only.

@MainActor
final class UsageStore: ObservableObject {
    @Published var tools: [Tool] = []
    @Published var lastUpdated: Date?
    @Published var loading = false

    // Did the fetch that just finished come back with any provider in error? `absorb`
    // deliberately hides those failures behind the last good reading, so `tools` can't
    // answer this — the refresh button is the only place a failed fetch can surface, and
    // it reads this on the falling edge of `loading`. Set before `loading` clears so the
    // two land in the same view update.
    @Published var lastFetchFailed = false

    // Injectable seams. `now` defaults to `Date()`; tests pin it for deterministic
    // timing. `fetcher` defaults to `LiveFetcher`; tests pass a mock.
    var now: () -> Date = { Date() }
    var fetcher: UsageFetcher = LiveFetcher()

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

    // Milestone tracking — the last 10% band we saw per *window*, keyed
    // "Tool|Metric|Slot". One bucket per tool wasn't enough: a tool's metrics move
    // independently (Claude's 5 h session sits far above its weekly), so tracking only
    // the highest one meant a weekly 18→21 crossing was invisible, and a session reset
    // flipping which metric is highest made the bucket lurch and eat real crossings.
    // The slot term disambiguates Codex primary/secondary when both share a label.
    private var lastBucket: [String: Int] = [:]

    // Crossings waiting for their moment on the lip. Detection can turn up several at
    // once (two windows, two providers, or a refresh triggered by opening the card),
    // and each one gets played in turn instead of the loudest silently winning.
    private var milestoneQueue: [MilestoneEvent] = []
    private let maxQueued = 6

    // Politeness throttle. Claude's usage endpoint is shared per-account — the CLI
    // polls it too — so automatic triggers (file activity, backstop) fetch at most
    // once per `baseGap`, minimising overlap with the CLI's own requests.
    private var backstopTask: Task<Void, Never>?
    private var pendingRefresh = false
    var lastRefreshAt: Date?
    var baseGap: TimeInterval = 300      // ≥5 min between automatic fetches

    // The local providers get their own, much shorter gap. Nothing about reading a
    // jsonl and a SQLite file needs politeness — `localGap` exists only to keep a
    // burst of Codex session writes from re-reading the same file dozens of times.
    private var pendingLocal = false
    private var lastLocalAt: Date?
    var localGap: TimeInterval = 3

    // Hard safety gate. Measured: the endpoint trips on the ~3rd request inside a
    // ~30 s sliding window that EVERY request re-extends (even 429s), and recovers
    // only after ~20–30 s of total silence. So `refresh()` enforces a floor between
    // any two requests, and a longer silence after a 429 — a single pending fire
    // (`flushTask`) coalesces everything, and every path (manual, launch, retry)
    // goes through this same gate so none can make the request that trips it.
    private var flushTask: Task<Void, Never>?
    var nextAllowed = Date.distantPast
    var minSpacing: TimeInterval = 30
    // True from the moment refresh() commits to fetching until it has published.
    private var inFlight = false

    // Would a refresh right now actually send, or would the gate swallow it? The refresh
    // button asks before it calls, because a swallowed refresh returns without ever
    // touching `loading` — so nothing downstream of `loading` can tell that a tap
    // happened, and the button has to answer that tap itself.
    var canFetchNow: Bool { now() >= nextAllowed }
    var rlStrikes = 0
    var coolDowns: [TimeInterval] = [45, 120, 300, 900, 1800]

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
        // One fetch at a time. `nextAllowed` spaces requests 30 s apart, which is
        // longer than a healthy fetch takes — but the subprocess reads have their own
        // (much longer) ceiling, so a Keychain prompt or a locked SQLite file can keep
        // one alive past the gate. Without this, every trigger that arrived after the
        // gate reopened would start a whole second fetch on top of the stuck one,
        // each spawning another blocked child. Re-entrants return without scheduling
        // a flush: the fetch already in flight is about to publish the same data.
        guard !inFlight else { return }
        let now = self.now()
        if now < nextAllowed {
            scheduleFlush(at: nextAllowed)
            return
        }
        inFlight = true
        defer { inFlight = false }
        nextAllowed = now.addingTimeInterval(minSpacing)   // reserve this slot up front
        lastRefreshAt = now
        loading = true
        async let claude = fetcher.fetchClaude()
        async let codex = fetcher.fetchCodex()
        async let opencode = fetcher.fetchOpenCode()
        let fresh = await [claude, codex, opencode]

        absorb(fresh)
        self.lastUpdated = self.now()
        self.lastFetchFailed = fresh.contains { $0.failed != nil }
        self.loading = false

        // 429 recovery: go fully silent for a cooldown (measured recovery ≈ 20–30 s,
        // escalating only if it persists) and queue exactly one retry at the end of
        // that silence. On success, reset — a transient blip clears itself.
        let rateLimited = fresh.contains { $0.failed?.contains("Rate limited") ?? false }
        if rateLimited {
            rlStrikes = min(rlStrikes + 1, coolDowns.count)
            nextAllowed = self.now().addingTimeInterval(coolDowns[rlStrikes - 1])
            scheduleFlush(at: nextAllowed)
        } else {
            rlStrikes = 0
        }

        detectMilestone()
    }

    // Fold fetched readings into `tools`: a good reading replaces its provider in
    // place, a failed or empty one falls back to the last good reading we have. In
    // place matters — it lets a local-only refresh update Codex and OpenCode without
    // disturbing Claude's numbers.
    private func absorb(_ incoming: [Tool]) {
        for t in incoming {
            let resolved: Tool
            if t.failed == nil && !t.metrics.isEmpty {
                lastGood[t.name] = t
                resolved = t
            } else {
                resolved = lastGood[t.name] ?? t
            }
            if let i = tools.firstIndex(where: { $0.name == resolved.name }) {
                tools[i] = resolved
            } else {
                tools.append(resolved)
            }
        }
        applyOrder()
    }

    // Codex and OpenCode read local files — no network, no shared endpoint, nothing to
    // be polite about. They used to queue behind Claude's 300 s gap, so a crossing that
    // FSEvents saw instantly could sit unannounced for minutes: Codex hit 20% at
    // 17:50:34 and the pulse wasn't due until 17:55:08. Now they have their own fast
    // path and only Claude waits on the network gate.
    //
    // `lastUpdated` is deliberately left alone here: it labels the whole card, and
    // Claude's number is the headline, so a local read shouldn't claim the card is
    // fresher than the last actual fetch. `loading` likewise stays off — there's no
    // request in flight to spin for.
    func refreshLocalTools() {
        if let last = lastLocalAt {
            let elapsed = now().timeIntervalSince(last)
            if elapsed < localGap {
                guard !pendingLocal else { return }      // already one queued
                pendingLocal = true
                let delay = localGap - elapsed
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self?.pendingLocal = false
                    await self?.readLocalTools()
                }
                return
            }
        }
        Task { @MainActor [weak self] in await self?.readLocalTools() }
    }

    private func readLocalTools() async {
        lastLocalAt = now()
        async let codex = fetcher.fetchCodex()
        async let opencode = fetcher.fetchOpenCode()
        absorb(await [codex, opencode])
        // Claude's readings are untouched above, so its buckets simply re-confirm and
        // only a real local crossing can fire here.
        detectMilestone()
    }

    // Coalesce every deferred request into a single fire at `when` — so no matter
    // how many triggers pile up during the gate, only one request goes out.
    private func scheduleFlush(at when: Date) {
        guard flushTask == nil else { return }
        let delay = max(0, when.timeIntervalSince(now()))
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
            let elapsed = now().timeIntervalSince(last)
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

    // Fire a milestone when any usage window enters a higher 10% band. Every metric of
    // every tool is tracked independently, so the 5 h session and the weekly window each
    // get their own crossings; on a window reset the value drops and we just re-arm that
    // band without firing. Several crossings in one refresh all get queued — the highest
    // band leads, the rest follow, none are dropped.
    func detectMilestone() {
        var crossed: [MilestoneEvent] = []
        for tool in tools {
            for m in tool.metrics {
                guard let pct = m.percent else { continue }      // e.g. OpenCode's $ spend
                // Slot disambiguates metrics that share a label (Codex primary/secondary).
                // Without it, two "Weekly" metrics collapsed into one bucket and one of
                // the two crossings went unannounced.
                let key = "\(tool.name)|\(m.label)|\(m.slot ?? "-")"
                let bucket = Int(pct / 10) * 10
                let prev = lastBucket[key]
                lastBucket[key] = bucket
                guard let prev, bucket > prev, bucket > 0 else { continue }
                crossed.append(MilestoneEvent(tool: tool.name, logoKey: tool.logoKey,
                                              from: prev, bucket: bucket, percent: pct,
                                              metricLabel: m.label))
            }
        }
        guard !crossed.isEmpty else { return }
        milestoneQueue += crossed.sorted { $0.bucket > $1.bucket }   // most urgent first
        if milestoneQueue.count > maxQueued {                        // drop the stalest
            milestoneQueue.removeFirst(milestoneQueue.count - maxQueued)
        }
        dequeueMilestone()
    }

    // Hand the next crossing to the view, unless one is still playing. The hop off the
    // current turn matters: @Published emits in `willSet`, so publishing from inside a
    // subscriber's callback would be a re-entrant mutation.
    private func dequeueMilestone() {
        guard milestone == nil, !milestoneQueue.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self, self.milestone == nil, !self.milestoneQueue.isEmpty else { return }
            self.milestone = self.milestoneQueue.removeFirst()
        }
    }

    // The view finished playing a crossing — clear the slot and offer the next.
    func milestoneDidFinish() {
        milestone = nil
        dequeueMilestone()
    }

    // The view couldn't play this one (the card is open, so the number is already on
    // screen). Park it at the head of the queue and stay quiet until `resumeMilestones()`
    // — otherwise re-offering it immediately would spin.
    func milestoneDeferred(_ event: MilestoneEvent) {
        milestone = nil
        milestoneQueue.insert(event, at: 0)
        if milestoneQueue.count > maxQueued { milestoneQueue.removeLast() }
    }

    // The card closed: anything parked can have the lip now.
    func resumeMilestones() { dequeueMilestone() }

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
