import SwiftUI
import Foundation

// One usage reading at a moment in time.
struct Sample: Codable {
    let t: Date
    let v: Double
}

// Rolling 24h history of every percent-bearing metric, persisted to a small JSON
// file in Application Support. The view records into it whenever `store.tools`
// changes and reads a series back to draw a trend under each bar. All access is
// main-actor; the disk write is handed to a detached task so it never blocks a
// frame. This is deliberately decoupled from the fetchers — it only observes the
// published tools, so it doesn't touch the polling code at all.
@MainActor
final class History: ObservableObject {
    @Published private(set) var series: [String: [Sample]] = [:]

    private let window: TimeInterval = 24 * 3600
    private let fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Token Usage Island", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }()

    init() { load() }

    // Metrics are keyed by tool + label because a Tool's `id` is a fresh UUID on
    // every poll — the (name, label) pair is the stable identity across refreshes.
    static func key(_ tool: String, _ label: String) -> String { "\(tool)/\(label)" }

    func values(tool: String, label: String) -> [Double] {
        (series[Self.key(tool, label)] ?? []).map(\.v)
    }

    // Append the current percents, trim to the 24h window, and persist. Skips a
    // reading identical to the last one within 30s, so the initial republish of a
    // @Published value can't double-log a point.
    func record(_ tools: [Tool], at now: Date) {
        var changed = false
        for t in tools {
            for m in t.metrics {
                guard let p = m.percent else { continue }
                let k = Self.key(t.name, m.label)
                var arr = series[k] ?? []
                if let last = arr.last, last.v == p, now.timeIntervalSince(last.t) < 30 { continue }
                arr.append(Sample(t: now, v: p))
                arr.removeAll { now.timeIntervalSince($0.t) > window }
                series[k] = arr
                changed = true
            }
        }
        if changed { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [Sample]].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-window)
        series = decoded.mapValues { $0.filter { $0.t >= cutoff } }
    }

    private func save() {
        let snapshot = series
        let url = fileURL
        Task.detached {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

// A minimal 24h trend line: the series normalized 0–100 over the row width.
// Purely contextual under the exact-value bar — no axes, no interaction.
struct Sparkline: View {
    let values: [Double]
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(values.count - 1)
                    let y = h - h * CGFloat(min(max(v, 0), 100) / 100)
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(accent.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
    }
}
