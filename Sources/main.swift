import AppKit
import SwiftUI
import Combine
import CoreServices   // FSEvents — watch the local coding-tool files for activity

// Watches a set of directories via FSEvents and calls `onChange` (coalesced by the
// stream's own latency) whenever anything under them is written. This is our
// "webhook" for the local tools: Codex session logs and the OpenCode DB change
// only while you're actually coding, so a change is our cue that usage has moved.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "island.fswatch")

    init(paths: [String], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        guard !paths.isEmpty, stream == nil else { return }
        var ctx = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer
                         | kFSEventStreamCreateFlagFileEvents
                         | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx,
            paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,                       // coalesce bursts of writes over ~2s
            flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // The existing coding-tool data dirs, so we never hand FSEvents a missing path.
    static func codingToolPaths() -> [String] {
        let fm = FileManager.default
        return ["~/.codex/sessions", "~/.local/share/opencode"]
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { fm.fileExists(atPath: $0) }
    }
}

// Measure content size and report upward.
struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct RootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var state: IslandState
    var onQuit: () -> Void
    var onRefresh: () -> Void
    var onSize: (CGSize) -> Void

    var body: some View {
        IslandView(store: store, state: state, onQuit: onQuit, onRefresh: onRefresh)
            .padding(.horizontal, 20)  // room for the card shadow + hover glow
            .padding(.bottom, 22)
            // NB: no top padding — the notch tab must sit flush with the screen edge.
            // Measure the FINAL padded size so the window tracks hover growth too.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: SizeKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(SizeKey.self) { size in
                onSize(size)
            }
    }
}

// Notch metrics for simulating other MacBooks on one machine, for testing the
// per-model layout without the hardware. Real hardware always uses live
// measurement; this only kicks in via env vars.
//   TUI_SIMULATE=mbp14|mbp16|air13|air15   — named preset
//   TUI_NOTCH_W=<pt> TUI_NOTCH_H=<pt>       — explicit override (takes precedence)
enum NotchSim {
    // Approximate point metrics at each model's default "looks like" resolution.
    // Widths differ with scaling; heights (menu-bar/notch) are ~all the same.
    static let presets: [String: (w: CGFloat, h: CGFloat)] = [
        "air13": (170, 38),   // 13" MacBook Air (M2/M3) — narrowest notch
        "mbp14": (184, 38),   // 14" MacBook Pro
        "air15": (185, 38),   // 15" MacBook Air
        "mbp16": (189, 38),   // 16" MacBook Pro — widest
    ]

    static func fromEnvironment() -> (width: CGFloat, height: CGFloat)? {
        let env = ProcessInfo.processInfo.environment
        var w: CGFloat?
        var h: CGFloat?
        if let name = env["TUI_SIMULATE"], let p = presets[name.lowercased()] {
            w = p.w; h = p.h
        }
        if let s = env["TUI_NOTCH_W"], let v = Double(s) { w = CGFloat(v) }
        if let s = env["TUI_NOTCH_H"], let v = Double(s) { h = CGFloat(v) }
        guard let width = w else { return nil }
        return (width, h ?? 38)
    }
}

// Auto-detected MacBook model + its notch metrics. Live screen measurement is
// still preferred (it tracks display scaling); this is the labelled fallback and
// a launch-time diagnostic so we can confirm handling on each machine.
struct MacModel {
    let id: String          // e.g. "Mac15,3"
    let name: String        // e.g. "MacBook Pro 14\""
    let notch: (w: CGFloat, h: CGFloat)?   // nil = no notch (or unknown)

    static func detect() -> MacModel {
        let id = Self.hardwareID()
        if let m = Self.table[id] { return MacModel(id: id, name: m.name, notch: m.notch) }
        // Unknown id: guess family from the identifier so new models still work.
        let name = id.contains("Air") || id.hasPrefix("Mac16,12") || id.hasPrefix("Mac16,13")
            ? "MacBook Air" : (id.contains("Pro") ? "MacBook Pro" : id)
        return MacModel(id: id, name: name, notch: nil)
    }

    private static func hardwareID() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    // Notched MacBooks. Widths are point metrics at the default "looks like"
    // resolution; heights (~menu-bar) are near-constant. Best-effort — a missing
    // future model just falls back to live measurement, which is authoritative.
    private static let table: [String: (name: String, notch: (w: CGFloat, h: CGFloat)?)] = [
        // 14"/16" MacBook Pro — 2021 (M1 Pro/Max)
        "MacBookPro18,3": ("MacBook Pro 14\"", (184, 38)),
        "MacBookPro18,4": ("MacBook Pro 14\"", (184, 38)),
        "MacBookPro18,1": ("MacBook Pro 16\"", (189, 38)),
        "MacBookPro18,2": ("MacBook Pro 16\"", (189, 38)),
        // 14"/16" MacBook Pro — 2023 (M2 Pro/Max)
        "Mac14,5":  ("MacBook Pro 14\"", (184, 38)),
        "Mac14,9":  ("MacBook Pro 14\"", (184, 38)),
        "Mac14,6":  ("MacBook Pro 16\"", (189, 38)),
        "Mac14,10": ("MacBook Pro 16\"", (189, 38)),
        // 14"/16" MacBook Pro — late 2023 (M3 family)
        "Mac15,3":  ("MacBook Pro 14\"", (184, 38)),
        "Mac15,6":  ("MacBook Pro 14\"", (184, 38)),
        "Mac15,8":  ("MacBook Pro 14\"", (184, 38)),
        "Mac15,10": ("MacBook Pro 14\"", (184, 38)),
        "Mac15,7":  ("MacBook Pro 16\"", (189, 38)),
        "Mac15,9":  ("MacBook Pro 16\"", (189, 38)),
        "Mac15,11": ("MacBook Pro 16\"", (189, 38)),
        // 14"/16" MacBook Pro — 2024 (M4 family)
        "Mac16,1":  ("MacBook Pro 14\"", (184, 38)),
        "Mac16,6":  ("MacBook Pro 14\"", (184, 38)),
        "Mac16,8":  ("MacBook Pro 14\"", (184, 38)),
        "Mac16,5":  ("MacBook Pro 16\"", (189, 38)),
        "Mac16,7":  ("MacBook Pro 16\"", (189, 38)),
        // MacBook Air 13"/15" — M2/M3/M4 (narrower notch)
        "Mac14,2":  ("MacBook Air 13\"", (170, 38)),
        "Mac14,15": ("MacBook Air 15\"", (185, 38)),
        "Mac15,12": ("MacBook Air 13\"", (170, 38)),
        "Mac15,13": ("MacBook Air 15\"", (185, 38)),
        "Mac16,12": ("MacBook Air 13\"", (170, 38)),
        "Mac16,13": ("MacBook Air 15\"", (185, 38)),
    ]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    let state = IslandState()
    let model = MacModel.detect()
    var window: NSPanel!
    var hosting: NSHostingView<RootView>!
    var watcher: FileWatcher?
    var bag = Set<AnyCancellable>()
    var currentSize: CGSize = .zero
    // The panel is created off-screen and only shown once positioned at the notch,
    // so it never appears to travel up from the bottom-left on launch.
    var didAppear = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let root = RootView(
            store: store,
            state: state,
            onQuit: { NSApp.terminate(nil) },
            onRefresh: { [weak self] in self?.doRefresh() },
            onSize: { [weak self] size in self?.updateWindowSize(size) }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        self.hosting = hosting

        updateNotchGeometry()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false   // no halo around the notch tab; the card draws its own shadow
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        self.window = panel

        // NB: no orderFront here — the first successful reposition() reveals the
        // panel once it's already sitting at the notch (see didAppear), so it
        // never flashes at the bottom-left default position and travels up.

        // QA: open the lip + card at launch so screenshots capture the full UI.
        if ProcessInfo.processInfo.environment["TUI_PREVIEW"] == "1" {
            state.forceReveal = true
            state.expanded = true
        }

        // Initial layout once SwiftUI has measured its content.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.layoutFromHosting()
        }

        // Refresh on each expand (throttled — a rapid re-open won't refetch).
        state.$expanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                guard let self else { return }
                if expanded {
                    self.store.requestRefresh()
                    // Size the window to hold the card RIGHT AWAY (next runloop, once
                    // SwiftUI has it in layout), non-animated and centered on the notch.
                    // The visible open is the card's own .cardUnfold transition — the
                    // window just has to be the correct size/position from frame one. The
                    // content overflows a too-small window (the panel doesn't clip), so a
                    // late resize made the card spawn offset to the side and then jump
                    // into place. Snapping immediately keeps it centered throughout.
                    DispatchQueue.main.async {
                        self.currentSize = self.hosting.fittingSize
                        self.reposition(animated: false)
                    }
                } else {
                    // Shrink only AFTER the card has folded away, so the window doesn't
                    // cut off the closing transition.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                        self.currentSize = self.hosting.fittingSize
                        self.reposition(animated: false)
                    }
                }
            }
            .store(in: &bag)

        // Content height can change when data arrives.
        store.$tools
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.layoutFromHosting()
                }
            }
            .store(in: &bag)

        // One fetch at launch so the collapsed pill has a value. After that, refreshes
        // are event-driven: an FSEvents watch on the local coding-tool files triggers
        // a (throttled) refresh whenever you're actively coding, plus a slow 15-min
        // backstop for idle. Every trigger routes through the ≤1/5-min throttle, so we
        // never hammer Claude's shared usage endpoint.
        doRefresh()
        store.startBackstop()

        watcher = FileWatcher(paths: FileWatcher.codingToolPaths()) { [weak self] in
            // FSEvents fires on a background queue — hop to main for the store.
            DispatchQueue.main.async {
                // The write we just saw IS the local tools' new usage: read it now, so a
                // Codex milestone lands while you're still looking at what caused it.
                self?.store.refreshLocalTools()
                // Coding activity usually means Claude moved too — ask, but politely.
                self?.store.requestRefresh()
            }
        }
        watcher?.start()

        // Reposition if displays change.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            // Observer already runs on the main queue; bind a strong `self` so the
            // hop below captures an immutable let (portable across Swift toolchains).
            guard let self else { return }
            DispatchQueue.main.async {
                self.updateNotchGeometry()
                self.layoutFromHosting()
            }
        }
    }

    // We're a notch overlay and never want app focus. A Finder/Spotlight double-click
    // (or plain `open -a`) *activates* us on launch, and that activation is what makes
    // WindowServer flash the Spaces bar — the desktop drops down and springs back — while
    // it hunts for a normal window of the newly-frontmost app on the current Space (our
    // panel is a high-level, all-spaces panel, which doesn't qualify). Immediately handing
    // activation back preempts that hunt. The `usage` CLI already launches with `open -g`
    // (no activation); this covers the double-click path Finder/Spotlight force on us.
    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.deactivate()
    }

    // macOS tears down FSEvents on process exit, but stopping the stream explicitly
    // (a) closes the dispatch queue cleanly, and (b) prevents a stray callback firing
    // during shutdown that could race the store's teardown. The 15-min backstop task
    // is cancelled for the same reason.
    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        store.stopBackstop()
    }

    func doRefresh() {
        Task { await store.refresh() }
    }

    // Read the active screen's real notch metrics into the view state.
    // Works on any MacBook: the notch size comes from the OS, not a hardcoded model.
    func updateNotchGeometry() {
        // Testing hook: simulate another MacBook without its hardware.
        if let sim = NotchSim.fromEnvironment() {
            state.hasNotch = true
            state.notchWidth = sim.width
            state.notchHeight = sim.height
            return
        }

        guard let screen = targetScreen() else { return }
        guard #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 else {
            state.hasNotch = false
            return
        }

        // A notch is present. Height is the safe-area inset; width is the gap between
        // the two menu-bar auxiliary areas.
        state.hasNotch = true
        state.notchHeight = screen.safeAreaInsets.top
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            state.notchWidth = screen.frame.width - l.width - r.width
            NSLog("[TokenUsageIsland] \(model.name) (\(model.id)) — notch \(Int(state.notchWidth))×\(Int(state.notchHeight)) (measured)")
        } else if let n = model.notch {
            // Aux areas unavailable — use the detected model's known width.
            state.notchWidth = n.w
            NSLog("[TokenUsageIsland] \(model.name) (\(model.id)) — notch \(Int(n.w))×\(Int(state.notchHeight)) (model fallback)")
        } else {
            // Unknown model with a notch — estimate from screen width.
            state.notchWidth = min(200, max(160, screen.frame.width * 0.12))
            NSLog("[TokenUsageIsland] \(model.id) — notch \(Int(state.notchWidth))×\(Int(state.notchHeight)) (estimated)")
        }
    }

    // Screen that has the notch, else the main screen.
    private func targetScreen() -> NSScreen? {
        if #available(macOS 12.0, *) {
            if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
                return notched
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    func updateWindowSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        currentSize = size
        // SwiftUI already animates the content (hover reveal / expand); snap the
        // window to each interpolated size so it tracks smoothly without double-animating.
        reposition(animated: false)
    }

    // Read the SwiftUI content's fitting size directly (robust vs. preference timing).
    func layoutFromHosting() {
        let s = hosting.fittingSize
        guard s.width > 1, s.height > 1 else { return }
        currentSize = s
        reposition(animated: true)
    }

    func reposition(animated: Bool = false) {
        guard let screen = targetScreen(), currentSize.width > 1 else { return }
        let w = currentSize.width
        let h = currentSize.height
        let x = screen.frame.midX - w / 2
        // Anchor the top just under the menu bar. On a notched Mac this hugs the
        // notch; otherwise it hangs cleanly below the menu bar. Use the same
        // notch verdict the view uses so tab and window always agree.
        let menuBarH = screen.frame.maxY - screen.visibleFrame.maxY
        let topAnchor = state.hasNotch ? screen.frame.maxY : (screen.frame.maxY - menuBarH + 2)
        let y = topAnchor - h
        let frame = NSRect(x: x, y: y, width: w, height: h)
        // Hand the hover backstop the frame we're about to adopt. Set before the
        // setFrame calls below so the animated path can't leave it a frame behind.
        state.windowFrame = frame
        if !didAppear {
            // First real layout: snap straight to the notch (no animation) and only
            // then reveal the panel, so launch is a clean spawn in place.
            window.setFrame(frame, display: true)
            window.orderFrontRegardless()
            didAppear = true
            return
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.30
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
