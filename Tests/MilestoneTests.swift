import Foundation

@MainActor
struct MilestoneTests {

    static func run() async {
        await firstReadingDoesNotFire()
        await climbFiresCrossing()
        await resetReArmsLowerBand()
        await independentMetricsBothFire()
        await slotDisambiguatesSameLabel()
        await sameBandDoesNotFire()
        await queueCapacityDropsStalest()
        await deferredEventGoesToHead()
        await resumeMilestonesDequeues()
    }

    // First time a metric is seen, no crossing fires — the bucket just gets recorded.
    // Without this, every fresh reading would pulse the lip.
    static func firstReadingDoesNotFire() async {
        let store = makeStore()
        store.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Weekly", percent: 25)]
        store.detectMilestone()
        expectNil(store.milestone, "first sighting must not fire a crossing")
    }

    // Two readings, second climbs into a higher 10% band → fire.
    static func climbFiresCrossing() async {
        let store = makeStore()
        store.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Weekly", percent: 5)]
        store.detectMilestone()                    // bucket 0, no fire
        store.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Weekly", percent: 25)]
        store.detectMilestone()
        guard let event = await awaitMilestone(store) else {
            fail("milestone not published")
            return
        }
        expectEqual(event.tool, "Claude")
        expectEqual(event.from, 0)
        expectEqual(event.bucket, 20)
        expectEqual(event.percent, 25)
        expectEqual(event.metricLabel, "Weekly")
    }

    // Drop on a window reset drops the bucket; climbing back re-arms the band.
    // This is the regression that was already fixed once (see Data.swift lastBucket
    // comment), now locked down by a test.
    static func resetReArmsLowerBand() async {
        let store = makeStore()
        store.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Weekly", percent: 35)]
        store.detectMilestone()                    // bucket 30
        store.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Weekly", percent: 4)]
        store.detectMilestone()                    // bucket 0, prev=30 > 0 → no fire
        store.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Weekly", percent: 15)]
        store.detectMilestone()                    // bucket 10, prev=0 → fire 0→10
        guard let event = await awaitMilestone(store) else {
            fail("milestone not published after re-arm")
            return
        }
        expectEqual(event.from, 0)
        expectEqual(event.bucket, 10)
    }

    // 5h session and weekly are tracked independently — a weekly crossing must
    // not be hidden by the session's larger number. The classic bug this fixes
    // is "tracking only the highest metric means a 18→21 weekly crossing is invisible".
    static func independentMetricsBothFire() async {
        let store = makeStore()
        let claude = Tool(name: "Claude", logoKey: "claude", accent: CLAUDE_ACCENT,
                          metrics: [
                            Metric(label: "Session · 5h", percent: 8, detail: "", slot: nil),
                            Metric(label: "Weekly", percent: 18, detail: "", slot: nil),
                          ], subtitle: nil, failed: nil)
        store.tools = [claude]
        store.detectMilestone()                    // first read: no fires
        // Climb session 8→12 (0→10) and weekly 18→31 (10→30). Both fire.
        let next = Tool(name: "Claude", logoKey: "claude", accent: CLAUDE_ACCENT,
                        metrics: [
                          Metric(label: "Session · 5h", percent: 12, detail: "", slot: nil),
                          Metric(label: "Weekly", percent: 31, detail: "", slot: nil),
                        ], subtitle: nil, failed: nil)
        store.tools = [next]
        store.detectMilestone()                    // session 0→10 + weekly 10→30
        // Higher bucket first, so 30 (weekly) leads and 10 (session) follows.
        guard let first = await awaitMilestone(store) else {
            fail("first milestone not published")
            return
        }
        expectEqual(first.bucket, 30)
        expectEqual(first.metricLabel, "Weekly")
        store.milestoneDidFinish()
        guard let second = await awaitMilestone(store) else {
            fail("second milestone not published")
            return
        }
        expectEqual(second.bucket, 10)
        expectEqual(second.metricLabel, "Session · 5h")
    }

    // Two metrics with the same label but different slots (Codex primary/secondary
    // both weekly) must track independently. Without the slot in the bucket key,
    // one metric's crossings would shadow the other.
    static func slotDisambiguatesSameLabel() async {
        let store = makeStore()
        let codex = Tool(name: "Codex", logoKey: "codex", accent: CODEX_ACCENT,
                         metrics: [
                           Metric(label: "Weekly", percent: 5, detail: "", slot: "primary"),
                           Metric(label: "Weekly", percent: 5, detail: "", slot: "secondary"),
                         ], subtitle: nil, failed: nil)
        store.tools = [codex]
        store.detectMilestone()                    // both bucket 0, no fire
        let next = Tool(name: "Codex", logoKey: "codex", accent: CODEX_ACCENT,
                        metrics: [
                          Metric(label: "Weekly", percent: 35, detail: "", slot: "primary"),
                          Metric(label: "Weekly", percent: 22, detail: "", slot: "secondary"),
                        ], subtitle: nil, failed: nil)
        store.tools = [next]
        store.detectMilestone()
        // Two crossings: primary 0→30 and secondary 0→20.
        guard let first = await awaitMilestone(store) else {
            fail("first slot milestone not published")
            return
        }
        expectEqual(first.bucket, 30)
        store.milestoneDidFinish()
        guard let second = await awaitMilestone(store) else {
            fail("second slot milestone not published")
            return
        }
        expectEqual(second.bucket, 20)
    }

    // Reading the same band again must not re-fire.
    static func sameBandDoesNotFire() async {
        let store = makeStore()
        store.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Weekly", percent: 25)]
        store.detectMilestone()                    // bucket 20
        store.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Weekly", percent: 27)]
        store.detectMilestone()                    // still bucket 20 → no fire
        expectNil(store.milestone)
    }

    // Queue capacity is bounded so a runaway burst can't pile up forever. A burst
    // of 12 crossings should leave at most maxQueued (6) in the queue, with the
    // most urgent kept and the stalest dropped.
    static func queueCapacityDropsStalest() async {
        let store = makeStore()
        // Seed six metrics' buckets at 0…
        for i in 0..<6 {
            store.tools.append(tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                                    label: "M\(i)", percent: 0))
        }
        store.detectMilestone()                    // record initial buckets
        // …climb each to a different higher band. That fires 6 crossings.
        for i in 0..<6 {
            store.tools[i] = tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                                  label: "M\(i)", percent: Double(20 + i * 10))
        }
        store.detectMilestone()                    // 6 crossings queued
        // Add another burst of 6 with even higher bands — the stalest from the
        // first batch should be dropped to stay under the cap.
        for i in 0..<6 {
            store.tools[i] = tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                                  label: "M\(i)", percent: Double(40 + i * 10))
        }
        store.detectMilestone()                    // 6 more, oldest 6 get dropped
        // Play through up to maxQueued; the rest should be silently gone.
        var allAbove40 = true
        for _ in 0..<6 {
            guard let event = await awaitMilestone(store) else { break }
            if event.bucket < 40 { allAbove40 = false }
            store.milestoneDidFinish()
        }
        expect(allAbove40, "only the newest burst should remain after the cap")
        // After playing the 6, the next attempt should be empty.
        let drained = await awaitMilestoneDrained(store, timeout: 0.2)
        expect(drained, "queue should be empty once the 6 newest have played")
    }

    // milestoneDeferred puts the event at the head so it plays first after the
    // current one finishes; otherwise re-offering immediately would spin.
    static func deferredEventGoesToHead() async {
        let store = makeStore()
        let first = MilestoneEvent(tool: "Claude", logoKey: "claude",
                                   from: 0, bucket: 30, percent: 35, metricLabel: "Weekly")
        store.milestone = first
        let parked = MilestoneEvent(tool: "Codex", logoKey: "codex",
                                    from: 0, bucket: 10, percent: 15, metricLabel: "Weekly")
        store.milestoneDeferred(parked)
        // After deferring, the next queue head is the parked event.
        store.milestoneDidFinish()                 // finishes "first" → dequeues parked
        guard let dequeued = await awaitMilestone(store) else {
            fail("deferred milestone not published")
            return
        }
        expectEqual(dequeued.tool, "Codex")
        expectEqual(dequeued.bucket, 10)
    }

    // resumeMilestones after the card closes should re-offer anything parked.
    static func resumeMilestonesDequeues() async {
        let store = makeStore()
        let e = MilestoneEvent(tool: "Claude", logoKey: "claude",
                               from: 0, bucket: 20, percent: 25, metricLabel: "Weekly")
        store.milestoneDeferred(e)                 // queues at head, no current milestone
        store.resumeMilestones()
        guard let event = await awaitMilestone(store) else {
            fail("resumed milestone not published")
            return
        }
        expectEqual(event.bucket, 20)
    }
}
