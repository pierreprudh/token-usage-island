import SwiftUI

// Sizes derived from Apple's real notch metrics (185×32 pt on the 14"/16" MBP).
enum IslandSize {
    static let collapsedW: CGFloat = 150   // fallback width on non-notch displays
    static let lipHeight: CGFloat = 15     // summary strip below the notch line
    static let tabCorner: CGFloat = 11
    static let gap: CGFloat = 7            // float gap between notch tab and card
    static let expandedW: CGFloat = 300
    static let cornerExpanded: CGFloat = 18
}

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    // Real notch geometry of the active screen (points).
    @Published var hasNotch = false
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
}

struct IslandView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var state: IslandState
    var onQuit: () -> Void
    var onRefresh: () -> Void

    @State private var hovered = false

    private var tabWidth: CGFloat { state.hasNotch ? state.notchWidth : IslandSize.collapsedW }
    // Reveal the summary lip when hovered or open; at rest it's just the notch.
    private var revealed: Bool { hovered || state.expanded }
    private var baseTabHeight: CGFloat { state.hasNotch ? state.notchHeight : 20 }
    private var tabHeight: CGFloat { baseTabHeight + (revealed ? IslandSize.lipHeight : 0) }

    var body: some View {
        VStack(spacing: IslandSize.gap) {
            notchTab
            if state.expanded {
                lightCard
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: state.expanded)
        .onHover { hovering in
            if state.expanded {
                if !hovering && !state.pinned {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                        state.expanded = false
                    }
                }
            } else {
                // The main hover animation: the lip springs out with a little overgrow.
                withAnimation(.spring(response: 0.30, dampingFraction: 0.52)) {
                    hovered = hovering
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Notch tab — invisible at rest (blends with the notch), reveals on hover

    private var notchTab: some View {
        ZStack(alignment: .bottom) {
            Color.black
            HStack(spacing: 9) {
                logo("claude", 11, onLight: false)
                HStack(spacing: 11) {
                    lipStat("5h", store.claudePercent("Session"))
                    lipStat("7d", store.claudePercent("Weekly"))
                }
            }
            .padding(.bottom, 2)
            .frame(height: IslandSize.lipHeight)
            .opacity(revealed ? 1 : 0)
        }
        .frame(width: tabWidth, height: tabHeight)
        .clipShape(bottomRounded(IslandSize.tabCorner))
        .scaleEffect(hovered && !state.expanded ? 1.03 : 1.0, anchor: .top)
        .contentShape(Rectangle())
        .onTapGesture { state.expanded.toggle() }
    }

    // MARK: Light Control-Center card

    private var lightCard: some View {
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

            ForEach(Array(store.tools.enumerated()), id: \.element.id) { idx, tool in
                if idx > 0 {
                    Divider().padding(.horizontal, 15)
                }
                ToolRow(tool: tool)
            }

            HStack(spacing: 6) {
                if let ts = store.lastUpdated {
                    Text("Updated \(timeString(ts))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
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
        }
        .frame(width: IslandSize.expandedW)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: IslandSize.cornerExpanded, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: IslandSize.cornerExpanded, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: IslandSize.cornerExpanded, style: .continuous))
        .environment(\.colorScheme, .light)   // force the light Control-Center look
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
    }

    // A compact stat for the hover lip: percentage first, faint time label after ("12% 5h").
    @ViewBuilder
    private func lipStat(_ label: String, _ pct: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2.5) {
            if let p = pct {
                Text("\(Int(p.rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(barColor(p, accent: CLAUDE_ACCENT))
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tool.accent)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    logo(tool.logoKey, 14, onLight: true)
                    Text(tool.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let sub = tool.subtitle {
                        Text(sub)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
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
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
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
