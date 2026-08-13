import Foundation

@MainActor
struct MilestoneTests {

    static func run() async {
        await firstReadingDoesNotFire()
        await climbFiresCrossing()
        await multiBandJumpPlaysEachBand()
        await bucketsPersistAcrossRelaunch()
        await resetReArmDoesNotFireAfterRelaunch()
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
                            label: "Weekly", percent: 15)]
        store.detectMilestone()
        guard let event = await awaitMilestone(store) else {
            fail("milestone not published")
            return
        }
        expectEqual(event.tool, "Claude")
        expectEqual(event.from, 0)
        expectEqual(event.bucket, 10)
        expectEqual(event.percent, 15)
        expectEqual(event.metricLabel, "Weekly")
    }

    // A jump across several bands plays one beat per band, ascending, so no tens band
    // skips its moment. Intermediate beats carry their band as the percent (so an 80
    // beat tints amber even if the jump landed at 92); the final beat carries the real
    // reading.
    static func multiBandJumpPlaysEachBand() async {
        let store = makeStore()
        store.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Weekly", percent: 8)]
        store.detectMilestone()                    // bucket 0, arm
        store.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Weekly", percent: 38)]
        store.detectMilestone()                    // 0→30: beats 10, 20, 30
        var beats: [(from: Int, bucket: Int, percent: Double)] = []
        for _ in 0..<3 {
            guard let event = await awaitMilestone(store) else {
                fail("expected three beats for a three-band jump, got \(beats.count)")
                return
            }
            beats.append((event.from, event.bucket, event.percent))
            store.milestoneDidFinish()
        }
        expectEqual(beats.map { $0.from },    [0, 10, 20])
        expectEqual(beats.map { $0.bucket },  [10, 20, 30])
        expectEqual(beats.map { $0.percent }, [10, 20, 38])
        let drained = await awaitMilestoneDrained(store, timeout: 0.2)
        expect(drained, "exactly one beat per band — nothing extra queued")
    }

    // Bands survive a relaunch: a crossing that happens while the app is quit fires on
    // the first refresh of the next run instead of being silently re-armed away.
    static func bucketsPersistAcrossRelaunch() async {
        let first = makeStore()
        first.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Weekly", percent: 25)]
        first.detectMilestone()                    // arm bucket 20, persisted
        // "Relaunch": a fresh store that loads the persisted bands instead of wiping them.
        let second = makeStore(freshBuckets: false)
        second.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                             label: "Weekly", percent: 45)]
        second.detectMilestone()                   // 20→40 crossed while "quit"
        guard let event = await awaitMilestone(second) else {
            fail("crossing across relaunch not published")
            return
        }
        expectEqual(event.from, 20)
        expectEqual(event.bucket, 30)
        second.milestoneDidFinish()
        guard let next = await awaitMilestone(second) else {
            fail("second beat across relaunch not published")
            return
        }
        expectEqual(next.bucket, 40)
        second.clearBuckets()                      // don't leak into later tests
    }

    // A window that reset while the app was quit re-arms silently on the next run —
    // the persisted high band must not make the lower reading look like anything, and
    // the re-armed (lower) band must itself be persisted for the run after.
    static func resetReArmDoesNotFireAfterRelaunch() async {
        let first = makeStore()
        first.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Session · 5h", percent: 85)]
        first.detectMilestone()                    // arm bucket 80, persisted
        let second = makeStore(freshBuckets: false)
        second.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                             label: "Session · 5h", percent: 6)]
        second.detectMilestone()                   // reset while quit → re-arm 0, no fire
        expectNil(second.milestone, "a reset across relaunch must not fire")
        // The re-arm was persisted: a third run climbing to 15 fires 0→10.
        let third = makeStore(freshBuckets: false)
        third.tools = [tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                            label: "Session · 5h", percent: 15)]
        third.detectMilestone()
        guard let event = await awaitMilestone(third) else {
            fail("climb after persisted re-arm not published")
            return
        }
        expectEqual(event.from, 0)
        expectEqual(event.bucket, 10)
        third.clearBuckets()                       // don't leak into later tests
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
        // The metric that reached the highest band leads, its beats ascending: weekly
        // plays 20 then 30, and only then the session's 10.
        var played: [(bucket: Int, label: String)] = []
        for _ in 0..<3 {
            guard let event = await awaitMilestone(store) else {
                fail("expected three beats across the two metrics, got \(played.count)")
                return
            }
            played.append((event.bucket, event.metricLabel))
            store.milestoneDidFinish()
        }
        expectEqual(played.map { $0.bucket }, [20, 30, 10])
        expectEqual(played.map { $0.label },
                    ["Weekly", "Weekly", "Session · 5h"])
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
        // Two independent crossings: primary 0→30 (beats 10, 20, 30) leads on its
        // higher final band, then secondary 0→20 (beats 10, 20).
        var buckets: [Int] = []
        for _ in 0..<5 {
            guard let event = await awaitMilestone(store) else {
                fail("expected five beats across the two slots, got \(buckets.count)")
                return
            }
            buckets.append(event.bucket)
            store.milestoneDidFinish()
        }
        expectEqual(buckets, [10, 20, 30, 10, 20])
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

    // Queue capacity is bounded so a runaway burst can't pile up forever. Two bursts
    // of 6 single-band crossings should leave at most maxQueued (6) in the queue,
    // with the newest burst kept and the stalest dropped.
    static func queueCapacityDropsStalest() async {
        let store = makeStore()
        // Seed six metrics one band apart…
        for i in 0..<6 {
            store.tools.append(tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                                    label: "M\(i)", percent: Double(5 + i * 10)))
        }
        store.detectMilestone()                    // record initial buckets
        // …climb each exactly one band. That fires 6 crossings: 10…60.
        for i in 0..<6 {
            store.tools[i] = tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                                  label: "M\(i)", percent: Double(15 + i * 10))
        }
        store.detectMilestone()                    // 6 crossings queued
        // Another one-band burst — 20…70 — should push the stale first batch out.
        for i in 0..<6 {
            store.tools[i] = tool("Claude", logo: "claude", accent: CLAUDE_ACCENT,
                                  label: "M\(i)", percent: Double(25 + i * 10))
        }
        store.detectMilestone()                    // 6 more, oldest 6 get dropped
        // Play through up to maxQueued; only the second burst should remain,
        // highest band first.
        var buckets: [Int] = []
        for _ in 0..<6 {
            guard let event = await awaitMilestone(store) else { break }
            buckets.append(event.bucket)
            store.milestoneDidFinish()
        }
        expectEqual(buckets, [70, 60, 50, 40, 30, 20])
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
