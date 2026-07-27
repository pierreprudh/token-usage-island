import SwiftUI
import ServiceManagement

// Launch-at-login, backed by the modern ServiceManagement API (macOS 13+). The
// main app registers itself as a login item — no helper bundle needed. Returns
// the resulting on/off state so the UI only flips when the OS actually agreed.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func setEnabled(_ want: Bool) -> Bool {
        do {
            if want { try SMAppService.mainApp.register() }
            else    { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()   // e.g. the app isn't in /Applications yet
        }
        return enabled
    }
}

// Notch metrics are read live per-display (see updateNotchGeometry); these are
// only the size constants the layout adds on top of the measured notch.
enum IslandSize {
    static let collapsedW: CGFloat = 150   // fallback width on non-notch displays
    static let lipHeight: CGFloat = 15     // summary strip below the notch line
    static let tabCorner: CGFloat = 11
    static let gap: CGFloat = 7            // float gap between notch tab and card
    static let expandedW: CGFloat = 300
    static let cornerExpanded: CGFloat = 18
    // Narrowest the revealed lip may be, so the logo + two stats never clip on the
    // narrower Air notches. Wider notches (14"/16" MBP) keep their measured width.
    static let minRevealW: CGFloat = 176
}

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    // Real notch geometry of the active screen (points).
    @Published var hasNotch = false
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    // QA only: force the lip/card open for screenshots (TUI_PREVIEW=1).
    @Published var forceReveal = false
    // One-shot launch greeting: the tab reveals, plays a loading bar, then settles.
    @Published var launching = false
    // One-shot milestone pulse: the tab reveals and glows when a new 10% band is hit.
    @Published var celebrating = false
    @Published var celebrateColor: Color = .white
}

struct IslandView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var state: IslandState
    var onQuit: () -> Void
    var onRefresh: () -> Void

    @State private var hovered = false
    @State private var launchBar: CGFloat = 0   // 0→1 fill for the launch loading bar
    @State private var didGreet = false
    @State private var milestoneDisplay = 0     // the number rendered — rolls old→new
    @State private var milestoneShow = false    // reveal state for the numeral
    @State private var pulseOn = false          // warning-tier halo throb
    @State private var pulseStrength: CGFloat = 0   // 0 none · 0.5 amber · 1 red
    @State private var milestoneLogo = "claude" // which provider's mark to showcase
    @State private var milestonePeriod = ""     // which limit the crossed % is for — "5h" / "7d"
    @State private var cardShown = false         // card opacity gate — animated apart from layout
    @State private var loginEnabled = false     // reflects SMAppService login-item state
    @State private var draggingTool: Tool?      // the row being drag-reordered, if any
    @State private var rowFrames: [UUID: CGRect] = [:]   // each row's slot, for drag hit-testing

    // At rest the tab is exactly the measured notch so it disappears into it.
    private var restTabWidth: CGFloat { state.hasNotch ? state.notchWidth : IslandSize.collapsedW }
    // Reveal the summary lip when hovered or open; at rest it's just the notch.
    private var revealed: Bool { hovered || state.expanded || state.forceReveal || state.launching || state.celebrating }
    // When revealed, grow to at least minRevealW so content fits on narrow notches;
    // on wide notches this is a no-op (max keeps the measured width).
    private var tabWidth: CGFloat { revealed ? max(restTabWidth, IslandSize.minRevealW) : restTabWidth }
    private var baseTabHeight: CGFloat { state.hasNotch ? state.notchHeight : 20 }
    private var tabHeight: CGFloat { baseTabHeight + (revealed ? IslandSize.lipHeight : 0) }

    var body: some View {
        // The tab is pinned to the top and drawn ON TOP; the card is a separate layer
        // that sits a tab+gap below it and just fades in place. Decoupling them means the
        // island never rides the card's layout animation — opening reads as the card
        // appearing beneath a fixed notch, not the whole thing rising up from below.
        ZStack(alignment: .top) {
            if state.expanded || cardShown {
                menuCard
                    .padding(.top, tabHeight + IslandSize.gap)
                    .opacity(cardShown ? 1 : 0)
            }
            notchTab
        }
        // Decouple the card's appearance from the layout: the card enters/leaves the
        // layout INSTANTLY (so the window snaps and the tab never rides an animated
        // resize — that resize is what made the island dip and rise, "coming from the
        // bottom"), and only its opacity is animated. The tab holds dead still.
        .onChange(of: state.expanded) { _, open in
            withAnimation(.easeOut(duration: open ? 0.26 : 0.17)) { cardShown = open }
        }
        .onHover { hovering in
            // Always keep `hovered` in sync — otherwise it sticks `true` after the
            // card closes and the lip never retracts until a second hover cycle.
            withAnimation(.spring(response: 0.30, dampingFraction: 0.52)) {
                hovered = hovering
            }
            // Leaving an open (unpinned) card collapses it back to the lip — unless a
            // row is mid-drag, where the pointer may briefly stray outside the bounds.
            if state.expanded && !hovering && !state.pinned && draggingTool == nil {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                    state.expanded = false
                }
            }
        }
        // Reliable exit backstop: the child row hover areas can make the plain
        // `.onHover` above miss its exit, leaving the lip stuck open. This fires a
        // definitive `.ended` when the pointer truly leaves, so we always retract.
        .onContinuousHover { phase in
            // Ignore exits while a row is being dragged — the drag owns the pointer.
            if case .ended = phase, draggingTool == nil {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.52)) {
                    hovered = false
                }
                if state.expanded && !state.pinned {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                        state.expanded = false
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Notch tab — invisible at rest (blends with the notch), reveals on hover

    private var notchTab: some View {
        ZStack(alignment: .bottom) {
            Color.black
            // The three lip contents are layered and cross-faded by explicit opacity
            // rather than swapped via if/else. An animated if/else lets SwiftUI
            // cross-fade the *outgoing* branch, so the hover stats used to bleed through
            // while the launch greeting was revealing. Gating each layer's opacity keeps
            // exactly one visible at a time — the hover lip is pinned off whenever a
            // greeting or milestone owns the tab.
            ZStack {
                // Hover: the top-ordered provider's mark + its headline stats.
                hoverLip
                    .opacity(revealed && !state.launching && !(state.celebrating && !state.expanded) ? 1 : 0)

                // Launch greeting: all three provider marks + the loading bar.
                HStack(spacing: 9) {
                    trioLogos(13)
                    launchLoadingBar
                }
                .opacity(state.launching ? 1 : 0)

                // Milestone: showcase the crossed number (yields to an open card).
                milestoneLip
                    .opacity(state.celebrating && !state.expanded && !state.launching ? 1 : 0)
            }
            .padding(.bottom, 2)
            .fixedSize()   // keep intrinsic width; tabWidth guarantees room (never clips)
            .frame(height: IslandSize.lipHeight)
            .opacity(revealed ? 1 : 0)
        }
        .frame(width: tabWidth, height: tabHeight)
        .clipShape(bottomRounded(IslandSize.tabCorner))
        // Warning-tier throb: a subtle size pulse only — no halo/glow. Gentle at
        // amber, a touch stronger at red. Only the numeral carries colour.
        .scaleEffect(pulseOn ? 1 + 0.035 * pulseStrength : 1, anchor: .top)
        // Morph: a brief squash-and-stretch gives the tab a soft, gel-like give as
        // it opens — layered on top of the hover scale.
        .scaleEffect(x: milestoneShow ? 1.0 : (state.celebrating ? 0.97 : 1.0),
                     y: milestoneShow ? 1.0 : (state.celebrating ? 1.05 : 1.0),
                     anchor: .top)
        // Tab lifts a touch on hover, but the lift is tied to `hovered` alone — NOT to
        // `expanded` — so clicking to open the card doesn't snap the tab back down. The
        // island stays put while the card unfolds beneath it.
        .scaleEffect(hovered ? 1.03 : 1.0, anchor: .top)
        .contentShape(Rectangle())
        .onTapGesture { state.expanded.toggle() }
        .onAppear(perform: playLaunchGreeting)
        .onReceive(store.$milestone.compactMap { $0 }) { playMilestone($0) }
    }

    // The three provider marks overlapping like linked rings. Each sits in a black
    // circular container that blends into the notch (a "hidden" container), so the
    // front chip cleanly cuts the one behind — a faint ring defines the overlap edge.
    private func trioLogos(_ size: CGFloat) -> some View {
        let d = size * 1.2   // chip diameter — hugs the logo tightly
        return HStack(spacing: -d * 0.42) {
            chip("claude", size, d).zIndex(3)
            chip("codex", size, d).zIndex(2)
            chip("opencode", size, d).zIndex(1)
        }
    }

    private func chip(_ key: String, _ size: CGFloat, _ d: CGFloat) -> some View {
        logo(key, size, onLight: false)
            .frame(width: d, height: d)
            .background(Circle().fill(Color.black))
            .clipShape(Circle())
    }

    // A glassy launch "loading" cue: a frosted track with a glossy white fill that
    // catches a top sheen and casts a soft luminous glow — Apple-style glassmorphism.
    private var launchLoadingBar: some View {
        let w: CGFloat = 92, h: CGFloat = 4
        return Capsule()
            .fill(.ultraThinMaterial)                                   // frosted glass track
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .frame(width: w, height: h)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(                               // glossy fill
                        colors: [.white, .white.opacity(0.78)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: w * launchBar, height: h)
                    .overlay(alignment: .top) {                         // top sheen highlight
                        Capsule()
                            .fill(LinearGradient(
                                colors: [.white.opacity(0.9), .clear],
                                startPoint: .top, endPoint: .center))
                    }
                    .clipShape(Capsule())
                    .shadow(color: .white.opacity(0.55), radius: 4)     // soft luminous glow
            }
    }

    // One-shot: settle in place, spring the lip open with a little overgrow while a
    // loading bar sweeps, then collapse back into the notch. Skips during QA preview,
    // and won't fight the user if they hover/click mid-greeting.
    private func playLaunchGreeting() {
        guard !didGreet, !state.forceReveal else { return }
        didGreet = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            withAnimation(.spring(response: 0.34, dampingFraction: 0.52)) { state.launching = true }
            withAnimation(.easeInOut(duration: 0.75)) { launchBar = 1 }
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            withAnimation(.spring(response: 0.40, dampingFraction: 0.72)) { state.launching = false }
        }
    }

    // The crossed number, front and centre. A tinted rounded numeral next to the
    // Claude mark; the numeral springs up from small (see playMilestone).
    private var milestoneLip: some View {
        HStack(spacing: 7) {
            logo(milestoneLogo, 11, onLight: false)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(milestoneDisplay)%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(state.celebrateColor)
                    // The digits roll from the old band to the new one — Apple's native
                    // numeric morph — while the whole numeral eases in.
                    .contentTransition(.numericText(value: Double(milestoneDisplay)))
                // Which limit crossed — the 5 h session vs the 7 d weekly window — so a
                // "40%" pulse is never ambiguous about which ceiling it's climbing toward.
                if !milestonePeriod.isEmpty {
                    Text(milestonePeriod)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(state.celebrateColor.opacity(0.55))
                }
            }
            .scaleEffect(milestoneShow ? 1 : 0.7, anchor: .leading)
            .opacity(milestoneShow ? 1 : 0)
        }
    }

    // Short tag for which limit a milestone belongs to, matching the hover lip's
    // vocabulary: the rolling 5-hour session vs the 7-day weekly window.
    private func periodTag(_ label: String) -> String {
        let l = label.lowercased()
        if l.contains("5h") || l.contains("session") { return "5h" }
        if l.contains("week") { return "7d" }
        return ""
    }

    // Milestone tint: stays neutral white as usage climbs, and only turns warning
    // colours near the ceiling — no red until you're actually close to the limit.
    private func milestoneTint(_ pct: Double) -> Color {
        if pct >= 90 { return Color(red: 0.94, green: 0.33, blue: 0.31) }   // red
        if pct >= 80 { return Color(red: 0.96, green: 0.68, blue: 0.20) }   // amber
        return .white
    }

    // One-shot, Apple-motion style: the tab eases open, the number springs up into
    // place and holds, then everything settles back into the notch. No throb, no
    // repeat. Won't override an open card — the fresh number is already visible.
    private func playMilestone(_ event: MilestoneEvent) {
        guard !state.expanded, !state.forceReveal else { return }
        state.celebrateColor = milestoneTint(event.percent)
        milestoneLogo = event.logoKey
        milestonePeriod = periodTag(event.metricLabel)
        milestoneDisplay = event.from                                // start on the old band
        // Warning tiers get a throb: subtle at amber, stronger + doubled at red.
        pulseStrength = event.percent >= 90 ? 1.0 : (event.percent >= 80 ? 0.5 : 0)
        let pulseLegs = event.percent >= 90 ? 4 : 2                  // legs = 2 per full bloom
        Task { @MainActor in
            milestoneShow = false
            pulseOn = false
            // Rubbery open: a bouncy spring lets the width overshoot and settle.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) { state.celebrating = true }
            try? await Task.sleep(nanoseconds: 150_000_000)          // lip morphs open
            withAnimation(.spring(response: 0.46, dampingFraction: 0.66)) { milestoneShow = true }
            try? await Task.sleep(nanoseconds: 380_000_000)          // read the old number…
            // …then roll it up to the new band — the smooth numeric morph.
            withAnimation(.smooth(duration: 0.6)) { milestoneDisplay = event.bucket }
            if pulseStrength > 0 {
                try? await Task.sleep(nanoseconds: 260_000_000)      // let the roll land
                withAnimation(.easeInOut(duration: 0.5).repeatCount(pulseLegs, autoreverses: true)) {
                    pulseOn = true
                }
                try? await Task.sleep(nanoseconds: UInt64(Double(pulseLegs) * 0.5 * 1_000_000_000))
                pulseOn = false
                try? await Task.sleep(nanoseconds: 1_100_000_000)    // linger on the warning
            } else {
                try? await Task.sleep(nanoseconds: 2_400_000_000)    // hold on the new number
            }
            withAnimation(.easeIn(duration: 0.22)) { milestoneShow = false }
            withAnimation(.spring(response: 0.44, dampingFraction: 0.8)) { state.celebrating = false }
        }
    }

    // MARK: Control-Center card — follows the system light/dark appearance

    private var menuCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Usage")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(store.loading ? 360 : 0))
                        .animation(store.loading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                                   value: store.loading)
                }
                .buttonStyle(.plain)
                Button { state.pinned.toggle() } label: {
                    Image(systemName: state.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(state.pinned ? CLAUDE_ACCENT : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)
            .padding(.bottom, 10)

            // Drag any row to reorder the providers; the one on top drives the hover
            // lip. A DragGesture (not `.onDrag`) does the reordering — the notch panel
            // is a borderless non-activating window, so AppKit's native drag session
            // never starts, but SwiftUI gestures fire the same as the tap does.
            ForEach(Array(store.tools.enumerated()), id: \.element.id) { idx, tool in
                if idx > 0 {
                    Divider().padding(.horizontal, 15)
                }
                ToolRow(tool: tool, dragging: draggingTool?.id == tool.id)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: RowFrameKey.self,
                                               value: [tool.id: geo.frame(in: .named("reorder"))])
                    })
                    .zIndex(draggingTool?.id == tool.id ? 1 : 0)
                    .gesture(reorderGesture(tool))
            }

            HStack(spacing: 6) {
                if let ts = store.lastUpdated {
                    Text("Updated \(timeString(ts))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                loginToggle
                Text("·")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Button(action: onQuit) {
                    Text("Quit")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 15)
            .padding(.top, 9)
            .padding(.bottom, 12)
            .onAppear { loginEnabled = LoginItem.enabled }
        }
        .frame(width: IslandSize.expandedW)
        // Rows report their frames here so the drag can tell which slot the pointer is over.
        .coordinateSpace(name: "reorder")
        .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: IslandSize.cornerExpanded, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: IslandSize.cornerExpanded, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: IslandSize.cornerExpanded, style: .continuous))
        // No forced colorScheme — the card inherits the system appearance so it
        // matches whatever light/dark theme the Mac is currently using.
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
    }

    // Live row reorder. While a row is dragged we swap it into whichever slot the
    // pointer is over (the array move animates the hop); nothing touches the network,
    // and the new order is persisted only when the drag ends.
    private func reorderGesture(_ tool: Tool) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("reorder"))
            .onChanged { value in
                if draggingTool == nil { draggingTool = tool }
                guard let drag = draggingTool else { return }
                let y = value.location.y
                // The row the pointer currently sits over (skip the one being dragged).
                guard let target = store.tools.first(where: { t in
                        guard t.id != drag.id, let f = rowFrames[t.id] else { return false }
                        return y >= f.minY && y <= f.maxY
                      }),
                      let from = store.tools.firstIndex(where: { $0.id == drag.id }),
                      let to = store.tools.firstIndex(where: { $0.id == target.id })
                else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    store.tools.move(fromOffsets: IndexSet(integer: from),
                                     toOffset: to > from ? to + 1 : to)
                }
            }
            .onEnded { _ in
                if draggingTool != nil { store.persistOrder() }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { draggingTool = nil }
            }
    }

    // Footer control: one click registers/unregisters the login item. Only flips the
    // label once the OS confirms the new state (setEnabled returns the actual status).
    private var loginToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                loginEnabled = LoginItem.setEnabled(!loginEnabled)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: loginEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9, weight: .semibold))
                Text("Open at login")
                    .font(.system(size: 9.5, weight: .medium))
            }
            // Neutral, theme-aware tint — matches the adjacent Quit control rather
            // than borrowing a provider's brand colour.
            .foregroundStyle(loginEnabled ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(loginEnabled ? "Won't open automatically" : "Open automatically when you log in")
    }

    // The hover lip content: the provider the user dragged to the top, with its own
    // mark, accent and headline numbers. Providers without a percentage (pay-as-you-go)
    // fall back to their compact cost detail so the lip is never blank.
    @ViewBuilder
    private var hoverLip: some View {
        if let top = store.tools.first {
            HStack(spacing: 9) {
                logo(top.logoKey, 11, onLight: false)
                let pctMetrics = top.metrics.filter { $0.percent != nil }
                if pctMetrics.isEmpty {
                    Text(top.metrics.first?.detail.components(separatedBy: " · ").first ?? "—")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    HStack(spacing: 11) {
                        ForEach(pctMetrics.prefix(2)) { m in
                            lipStat(shortLabel(m.label), m.percent, accent: top.accent)
                        }
                    }
                }
            }
        }
    }

    // Compress a metric's full label to the two-or-three-character tag the lip shows.
    private func shortLabel(_ label: String) -> String {
        let l = label.lowercased()
        if l.contains("weekly") || l.contains("7d") || l.contains("week") { return "7d" }
        if l.contains("5h") || l.contains("session") { return "5h" }
        if l.contains("secondary") { return "2nd" }
        if l.contains("limit") { return "lim" }
        return String(label.prefix(3)).lowercased()
    }

    // A compact stat for the hover lip: percentage first, faint time label after ("12% 5h").
    @ViewBuilder
    private func lipStat(_ label: String, _ pct: Double?, accent: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2.5) {
            if let p = pct {
                Text("\(Int(p.rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(barColor(p, accent: accent))
            } else {
                Text("—")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}

// Rounded only at the bottom (top flush with the screen edge / notch).
func bottomRounded(_ r: CGFloat) -> some InsettableShape {
    UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: r,
                                              bottomTrailing: r, topTrailing: 0),
                           style: .continuous)
}

// Shared logo helper. `onLight` picks the variant/tint that reads on a light card.
@ViewBuilder
func logo(_ key: String, _ size: CGFloat, onLight: Bool) -> some View {
    switch key {
    case "codex":
        // The Codex mark is white → tint it dark on a light card.
        if let img = Logos.codex {
            Image(nsImage: img)
                .renderingMode(onLight ? .template : .original)
                .resizable().interpolation(.high).scaledToFit()
                .foregroundStyle(onLight ? Color(white: 0.12) : .white)
                .frame(width: size, height: size)
        }
    case "opencode":
        // Use the dark-colored block on light, the light-colored block on dark.
        if let img = onLight ? Logos.opencodeLight : Logos.opencodeDark {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
        }
    default: // claude — full-color, reads on both
        if let img = Logos.named(key) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkle").font(.system(size: size * 0.8))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Tool row

struct ToolRow: View {
    let tool: Tool
    var dragging: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                // Bare provider mark — colour identity lives in the meter below.
                logo(tool.logoKey, 15, onLight: colorScheme == .light)
                Text(tool.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                if let sub = tool.subtitle {
                    Text(sub)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // Grip affordance: fades in on hover to signal the row is draggable.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovered ? 0.55 : 0)
            }

            if let err = tool.failed {
                Text(err)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tool.metrics) { m in
                    MetricRow(metric: m, accent: tool.accent)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // On-hover: the row grows a touch — a smooth size cue, no colour fill.
        // While dragged it lifts a little more and casts a soft shadow, so the row
        // reads as picked-up as it hops between slots.
        .scaleEffect(dragging ? 1.05 : (hovered ? 1.04 : 1.0))
        .shadow(color: .black.opacity(dragging ? 0.22 : 0), radius: 8, y: 4)
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { hovered = h }
        }
    }
}

// Each provider row publishes its frame (in the card's "reorder" space) so the drag
// gesture can tell which slot the pointer is hovering. Frames merge into one dict.
struct RowFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct MetricRow: View {
    let metric: Metric
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3.5) {
            HStack(spacing: 6) {
                Text(metric.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.75))
                Spacer(minLength: 0)
                if let p = metric.percent {
                    Text("\(Int(p.rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                Text(metric.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            if let p = metric.percent {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(barColor(p, accent: accent))
                                .frame(width: max(3, geo.size.width * CGFloat(min(p, 100) / 100)))
                        }
                }
                .frame(height: 4.5)
            }
        }
    }
}
