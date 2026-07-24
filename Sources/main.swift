import AppKit
import SwiftUI
import Combine

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    let state = IslandState()
    var window: NSPanel!
    var hosting: NSHostingView<RootView>!
    var bag = Set<AnyCancellable>()
    var currentSize: CGSize = .zero

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

        panel.orderFrontRegardless()

        // Initial layout once SwiftUI has measured its content.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.layoutFromHosting()
        }

        // Fetch fresh values on each expand (the deliberate click); relayout always.
        state.$expanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                if expanded { self?.doRefresh() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    self?.layoutFromHosting()
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

        // One fetch at launch so the collapsed pill has a value. No polling loop —
        // values refresh only when the island is opened.
        doRefresh()

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

    func doRefresh() {
        Task { await store.refresh() }
    }

    // Read the active screen's real notch metrics into the view state.
    func updateNotchGeometry() {
        guard let screen = targetScreen() else { return }
        if #available(macOS 12.0, *),
           screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            state.hasNotch = true
            state.notchWidth = screen.frame.width - l.width - r.width
            state.notchHeight = screen.safeAreaInsets.top
        } else {
            state.hasNotch = false
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
        // notch; otherwise it hangs cleanly below the menu bar.
        let hasNotch: Bool = {
            if #available(macOS 12.0, *) { return screen.safeAreaInsets.top > 0 }
            return false
        }()
        let menuBarH = screen.frame.maxY - screen.visibleFrame.maxY
        let topAnchor = hasNotch ? screen.frame.maxY : (screen.frame.maxY - menuBarH + 2)
        let y = topAnchor - h
        let frame = NSRect(x: x, y: y, width: w, height: h)
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
