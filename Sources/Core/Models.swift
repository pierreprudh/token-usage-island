import Foundation

// MARK: - Colour
//
// A plain RGB triple rather than SwiftUI's `Color`. Severity ("how close to the
// ceiling is this?") is a property of the reading, not of the renderer, and it is
// wanted in places that have no UI framework at all — the `usage status` CLI tints
// its bars from exactly the same rule. Keeping `Color` out of the model is also what
// lets this whole layer compile against Foundation alone; the app adds a
// `Color(_: RGB)` bridge in one place and nothing else changes.
struct RGB: Equatable {
    let r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
}

let CLAUDE_ACCENT   = RGB(0.85, 0.47, 0.30)      // rust/orange
let CODEX_ACCENT    = RGB(0.470, 0.522, 0.922)   // Codex periwinkle-blue #7885EB
let OPENCODE_ACCENT = RGB(0.45, 0.55, 0.95)      // indigo

let SEVERITY_RED   = RGB(0.94, 0.33, 0.31)
let SEVERITY_AMBER = RGB(0.96, 0.68, 0.20)

// Severity color from a percent (shared across all tools for consistency)
func barColor(_ pct: Double?, accent: RGB) -> RGB {
    guard let p = pct else { return accent }
    if p >= 90 { return SEVERITY_RED }
    if p >= 70 { return SEVERITY_AMBER }
    return accent
}

// MARK: - Models

struct Metric: Identifiable {
    // Derived, not random. A fresh UUID per value meant every fetch produced
    // brand-new metrics as far as SwiftUI was concerned, so the card rebuilt each
    // row on every refresh. Label+slot is what actually makes a metric distinct
    // within a tool — the same pair the milestone bucket key is built from.
    var id: String { "\(label)|\(slot ?? "")" }
    let label: String        // "Session · 5h"
    let percent: Double?      // 0...100, nil if not a % metric
    let detail: String        // "Resets 17:30" or "$14.90 · 31M tok"
    // Disambiguates metrics that share a label. Used in the milestone bucket key so
    // Codex's primary and secondary (which can both be "Weekly") track independently
    // instead of one silently shadowing the other.
    let slot: String?
    init(label: String, percent: Double?, detail: String, slot: String? = nil) {
        self.label = label
        self.percent = percent
        self.detail = detail
        self.slot = slot
    }
}

struct Tool: Identifiable {
    // The name is already this type's primary key everywhere else: `absorb` matches
    // on it, `lastGood` and the persisted order are keyed by it, and so are the
    // milestone buckets. A random UUID here contradicted all of that — the fetchers
    // build a fresh Tool per call, so the card's ForEach saw three deletions and
    // three insertions on every refresh. Row hover state reset each time, and a
    // refresh landing mid-drag orphaned `draggingTool`, freezing the reorder.
    var id: String { name }
    let name: String
    let logoKey: String       // "claude" / "codex" / "opencode"
    let accent: RGB
    var metrics: [Metric]
    var subtitle: String?     // "Plus plan" / "pay-as-you-go"
    var failed: String?       // error message if fetch failed
}

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

// MARK: - Fetcher protocol (test seam)
//
// Every path that hits the network goes through `UsageStore.refresh()`, which calls
// `fetcher.fetchX()` for each provider. In production `LiveFetcher` reads the real
// Keychain/SQLite/JSONL; tests inject a `MockFetcher` that returns canned Tool values
// so the throttle/queue logic can be exercised without touching disk or network.
protocol UsageFetcher {
    func fetchClaude() async -> Tool
    func fetchCodex() async -> Tool
    func fetchOpenCode() async -> Tool
}

// MARK: - Formatting

func humanTokens(_ n: Double) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
    return String(format: "%.0f", n)
}

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
