import Foundation

// `usage status` — the island's numbers, without the island.
//
// This binary is built from Sources/Core minus Store.swift and nothing else. That is
// deliberate and load-bearing: if anything in the fetch layer ever grows a SwiftUI or
// AppKit dependency, this target stops compiling. The separation is checked by the
// build rather than asserted in a comment.
//
// It is also the answer for machines the island can't run on. Codex and OpenCode read
// local files and Claude is one authenticated HTTPS call, so the same three readings
// are available anywhere the coding tools are — the notch is a presentation choice,
// not a requirement.

// MARK: - Terminal

let useColor: Bool = {
    if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
    if CommandLine.arguments.contains("--no-color") { return false }
    return isatty(STDOUT_FILENO) == 1
}()

func tint(_ s: String, _ rgb: RGB) -> String {
    guard useColor else { return s }
    let r = Int(rgb.r * 255), g = Int(rgb.g * 255), b = Int(rgb.b * 255)
    return "\u{1B}[38;2;\(r);\(g);\(b)m\(s)\u{1B}[0m"
}
func dim(_ s: String) -> String { useColor ? "\u{1B}[2m\(s)\u{1B}[0m" : s }
func bold(_ s: String) -> String { useColor ? "\u{1B}[1m\(s)\u{1B}[0m" : s }

// A 20-cell meter using the same severity rule the island's bars use.
func meter(_ pct: Double, accent: RGB, width: Int = 20) -> String {
    let filled = max(0, min(width, Int((pct / 100 * Double(width)).rounded())))
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    return tint(bar, barColor(pct, accent: accent))
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

// MARK: - Rendering

func render(_ tools: [Tool]) -> String {
    var out = ""
    // One label column across every provider, so the meters line up as a single block.
    let labelWidth = max(12, tools.flatMap { $0.metrics }.map { $0.label.count }.max() ?? 12)

    for tool in tools {
        out += bold(tint(tool.name, tool.accent))
        if let sub = tool.subtitle { out += "  " + dim(sub) }
        out += "\n"

        if let err = tool.failed {
            out += "  " + dim(err) + "\n\n"
            continue
        }
        for m in tool.metrics {
            out += "  " + pad(m.label, labelWidth) + "  "
            if let p = m.percent {
                out += meter(p, accent: tool.accent)
                out += "  " + pad("\(Int(p.rounded()))%", 4)
            } else {
                // Pay-as-you-go has no ceiling to draw a meter against; the detail
                // column carries the whole reading instead.
                out += pad("", 20 + 6)
            }
            if !m.detail.isEmpty { out += "  " + dim(m.detail) }
            out += "\n"
        }
        out += "\n"
    }
    return out
}

func renderJSON(_ tools: [Tool]) -> String {
    let payload: [String: Any] = [
        "fetched_at": ISO8601DateFormatter().string(from: Date()),
        "tools": tools.map { t -> [String: Any] in
            var d: [String: Any] = ["name": t.name, "metrics": t.metrics.map { m -> [String: Any] in
                var md: [String: Any] = ["label": m.label, "detail": m.detail]
                if let p = m.percent { md["percent"] = p }
                if let s = m.slot { md["slot"] = s }
                return md
            }]
            if let s = t.subtitle { d["subtitle"] = s }
            if let f = t.failed { d["error"] = f }
            return d
        },
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                 options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

// MARK: - Fetch

func fetchAll() async -> [Tool] {
    async let claude = _fetchClaude()
    async let codex = _fetchCodex()
    async let opencode = _fetchOpenCode()
    return await [claude, codex, opencode]
}

// MARK: - Entry

let args = CommandLine.arguments.dropFirst()

if args.contains("--help") || args.contains("-h") {
    print("""
    usage status — Claude, Codex and OpenCode plan usage in the terminal

    USAGE
        usage status [options]

    OPTIONS
        --watch [seconds]   Re-read on an interval (default 60, minimum 30)
        --json              Machine-readable output
        --no-color          Disable ANSI colour (also honours NO_COLOR)
        -h, --help          Show this help

    NOTES
        Claude comes from the usage endpoint using the OAuth token Claude Code
        already stores; Codex and OpenCode are read from local files. The 30 s
        floor on --watch exists because the Claude endpoint is shared with the
        CLI itself and rate-limits per account.
    """)
    exit(0)
}

let wantJSON = args.contains("--json")
let wantWatch = args.contains("--watch")

// --watch may be followed by an interval. The floor matches the island's own minimum
// request spacing: the Claude usage endpoint is per-account and shared with the Claude
// Code CLI, and it rate-limits on roughly the third request in a 30 s window.
var interval: TimeInterval = 60
if let i = args.firstIndex(of: "--watch"), i + 1 < args.endIndex,
   let v = Double(args[i + 1]), v > 0 {
    interval = max(30, v)
}

let done = DispatchSemaphore(value: 0)
Task {
    repeat {
        let tools = await fetchAll()
        if wantJSON {
            print(renderJSON(tools))
        } else {
            if wantWatch { print("\u{1B}[2J\u{1B}[H", terminator: "") }   // clear + home
            print(render(tools), terminator: "")
            if wantWatch {
                print(dim("updated \(DateFormatter.hhmm.string(from: Date())) · every \(Int(interval))s · ^C to stop"))
            }
        }
        if wantWatch {
            // stdout is block-buffered when it isn't a terminal, so a watch piped to a
            // file or a pager showed nothing at all until the buffer happened to fill.
            // Each tick is a complete reading; push it out before sleeping on the next.
            fflush(stdout)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    } while wantWatch
    done.signal()
}
done.wait()

extension DateFormatter {
    static let hhmm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}
