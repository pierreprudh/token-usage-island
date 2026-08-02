import SwiftUI
import AppKit

// The bridge between the Foundation-only core and the UI. Everything that needs
// SwiftUI or AppKit to express a core value lives here, and it is deliberately thin:
// a colour conversion and the bundled artwork. Nothing in Sources/Core imports a UI
// framework, so this file is the whole cost of that separation.

extension Color {
    init(_ rgb: RGB) { self.init(red: rgb.r, green: rgb.g, blue: rgb.b) }
}

// Severity colour for a reading, already resolved to a SwiftUI Color. The rule itself
// lives in the core (the CLI tints its bars from the same one); this just converts.
func barTint(_ pct: Double?, accent: RGB) -> Color { Color(barColor(pct, accent: accent)) }

// Bundled provider logos (loaded once). NSImage renders the SVG natively.
enum Logos {
    static let claude = load("claude-code-logo", "png")
    static let codex = load("codex-logo", "png")
    static let opencodeDark = load("opencode-logo-dark", "svg")    // light block — for dark bg
    static let opencodeLight = load("opencode-logo-light", "svg")  // dark block — for light bg

    private static func load(_ name: String, _ ext: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: ext).flatMap { NSImage(contentsOf: $0) }
    }
    static func named(_ key: String) -> NSImage? {
        switch key {
        case "claude": return claude
        case "codex": return codex
        case "opencode": return opencodeDark
        default: return nil
        }
    }
}
