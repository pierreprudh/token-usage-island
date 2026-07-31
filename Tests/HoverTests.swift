import Foundation
import SwiftUI

// The hover backstop's boundary rules.
//
// `hovered` is driven by SwiftUI tracking areas, and this window calls setFrame on
// every interpolated frame of the reveal animation — a tracking area rebuilt mid-resize
// can drop the exit event and leave the lip stuck open with the pointer elsewhere. The
// backstop polls the real cursor against the real window frame instead of trusting that
// signal, and `pointerHasLeft` is the decision it makes each tick.
//
// The timing loop itself isn't covered here (it needs a live window and a real cursor);
// what's pinned down is the predicate, where the interesting mistakes live: an
// unmeasured frame must never read as "left", or the lip would retract before the first
// layout ever lands.
@MainActor
struct HoverTests {

    static func run() async {
        unmeasuredFrameNeverCountsAsLeft()
        pointerInsideIsNotLeft()
        pointerOutsideIsLeft()
        edgesCountAsInside()
    }

    // The guard that matters most. `IslandState.windowFrame` starts at .zero and is
    // only filled in by the first reposition(); if .zero read as "pointer has left",
    // the backstop would fire during launch and fight the reveal.
    static func unmeasuredFrameNeverCountsAsLeft() {
        let pointer = CGPoint(x: 700, y: 900)
        expect(!pointerHasLeft(pointer, windowFrame: .zero),
               "an unmeasured (.zero) frame must never retract the lip")
        // A degenerate sliver is equally untrustworthy — mid-layout the frame can be
        // 1pt tall for a beat, and every pointer on screen is outside that.
        expect(!pointerHasLeft(pointer, windowFrame: CGRect(x: 0, y: 0, width: 1, height: 1)),
               "a degenerate frame must not retract the lip either")
    }

    static func pointerInsideIsNotLeft() {
        let frame = CGRect(x: 600, y: 800, width: 340, height: 200)
        for p in [CGPoint(x: 770, y: 900),      // dead centre
                  CGPoint(x: 610, y: 810),      // near a corner, inside
                  CGPoint(x: 930, y: 990)] {    // near the far corner, inside
            expect(!pointerHasLeft(p, windowFrame: frame),
                   "pointer \(p) is inside \(frame) and must not retract")
        }
    }

    static func pointerOutsideIsLeft() {
        let frame = CGRect(x: 600, y: 800, width: 340, height: 200)
        for p in [CGPoint(x: 599, y: 900),      // just left
                  CGPoint(x: 941, y: 900),      // just right
                  CGPoint(x: 770, y: 799),      // just below
                  CGPoint(x: 770, y: 1001),     // just above
                  CGPoint(x: 100, y: 100)] {    // far away — the stuck-lip case
            expect(pointerHasLeft(p, windowFrame: frame),
                   "pointer \(p) is outside \(frame) and must retract")
        }
    }

    // The pointer resting exactly on the frame's origin edge still counts as inside,
    // matching CGRect.contains. Retracting on the boundary would make the lip flicker
    // for anyone tracing the notch's edge.
    static func edgesCountAsInside() {
        let frame = CGRect(x: 600, y: 800, width: 340, height: 200)
        expect(!pointerHasLeft(CGPoint(x: 600, y: 800), windowFrame: frame),
               "the origin corner is inside")
        // CGRect.contains excludes the far edges (maxX/maxY), so those DO read as left.
        expect(pointerHasLeft(CGPoint(x: 940, y: 1000), windowFrame: frame),
               "the far corner sits on maxX/maxY, which CGRect.contains excludes")
    }
}
