//
//  CompositorClockModelTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 16.08.2026.
//

import Foundation
import Testing

@testable import MayflowerStream

/// HaishinKit 2.2.5's compositor clock, reduced to the two pieces of arithmetic that decide whether a
/// composited frame is emitted or silently dropped: `Screen.makeSampleBuffer` (Screen.swift:177-181,
/// the high-water latch on the presentation timestamp) and `Screen.setVideoCaptureLatency`
/// (Screen.swift:221-227, the latency measured against the display link's last `targetTimestamp`).
/// `Screen.reset()` clears neither field, which is why a suspension leaves both stale.
///
/// A model rather than the library itself, which needs a display link, a camera and a pixel buffer
/// pool. If HaishinKit is ever bumped, the two characterisation tests below are the ones to re-read
/// against the new source: they are what makes the third — the lock on our own bring-up order — mean
/// anything.
struct CompositorClockModel {

    private(set) var targetTimestamp: TimeInterval = 0
    private var videoCaptureLatency: TimeInterval = 0
    private var presentationTimeStamp: TimeInterval = 0

    /// `Screen.makeSampleBuffer`: the stamp of the frame it emits, or `nil` for a frame the high-water
    /// guard swallows. Only a tick refreshes `targetTimestamp`, in a `defer`.
    mutating func displayLinkTick(at timestamp: TimeInterval, targetTimestamp: TimeInterval) -> TimeInterval? {
        defer { self.targetTimestamp = targetTimestamp }
        let stamp = timestamp - videoCaptureLatency
        guard presentationTimeStamp <= stamp else { return nil }
        presentationTimeStamp = stamp
        return stamp
    }

    /// `Screen.setVideoCaptureLatency`: how far behind the display link's last target this camera
    /// buffer is. A link that has not ticked since the suspension answers with the whole background
    /// duration, negated.
    mutating func cameraBuffer(at presentationTimeStamp: TimeInterval) {
        guard 0 < targetTimestamp else { return }
        videoCaptureLatency = ceil((targetTimestamp - presentationTimeStamp) * 10000) / 10000
    }
}

/// A composited frame as the model let it out: when the display link ticked, and what the compositor
/// stamped it with.
struct CompositedFrame: Sendable {
    let at: TimeInterval
    let stamp: TimeInterval
}

/// Runs a `CompositorClockModel` forward at a fixed frame rate. The display link ticks only while the
/// compositor runs and the camera delivers a buffer per frame interval once attached — the order
/// between those two is the whole bug, so the simulation lets a test choose it.
/// `@unchecked Sendable` because every mutable field is read and written under `lock`.
final class CompositorSimulation: @unchecked Sendable {

    static let frameInterval: TimeInterval = 1.0 / 30.0

    private let lock = NSLock()
    private var clock = CompositorClockModel()
    private var now: TimeInterval
    private var resumedAt: TimeInterval
    private var isCompositing = false
    private var isCameraAttached = false
    private var frames: [CompositedFrame] = []
    private var dropped = 0

    var emitted: [CompositedFrame] {
        lock.withLock { frames }
    }

    var droppedFrames: Int {
        lock.withLock { dropped }
    }

    var currentTime: TimeInterval {
        lock.withLock { now }
    }

    /// The longest stretch since the resume with no composited frame — the freeze, as the preview and
    /// the viewer on Twitch both experience it.
    var longestFreeze: TimeInterval {
        lock.withLock {
            var previous = resumedAt
            var longest: TimeInterval = 0
            for frame in frames {
                longest = max(longest, frame.at - previous)
                previous = frame.at
            }
            return max(longest, now - previous)
        }
    }

    init(startingAt time: TimeInterval) {
        now = time
        resumedAt = time
    }

    /// Leaves the model in the state a real suspension leaves it in: a session that composited
    /// normally until `backgroundDuration` ago, both stale fields still carrying its last values, and
    /// the counters cleared so only what happens after the resume is measured.
    func runUntilSuspended(forFrames frames: Int, thenBackgroundFor backgroundDuration: TimeInterval) {
        startCompositing()
        attachCamera()
        advance(byFrames: frames)
        stopCompositing()
        detachCamera()
        lock.withLock {
            now += backgroundDuration
            resumedAt = now
            self.frames.removeAll()
            dropped = 0
        }
    }

    func startCompositing() {
        lock.withLock { isCompositing = true }
    }

    func stopCompositing() {
        lock.withLock { isCompositing = false }
    }

    /// A camera delivers its first buffer as soon as it is attached — the device trace measured 0 and
    /// 21 ms — which is how one reaches the compositor before the display link has ticked.
    func attachCamera() {
        lock.withLock {
            isCameraAttached = true
            clock.cameraBuffer(at: now)
        }
    }

    func detachCamera() {
        lock.withLock { isCameraAttached = false }
    }

    func advance(byFrames frames: Int) {
        for _ in 0..<frames { advanceOneFrame() }
    }

    func advance(by duration: TimeInterval) {
        advance(byFrames: Int((duration / Self.frameInterval).rounded()))
    }

    func advanceOneFrame() {
        lock.withLock {
            now += Self.frameInterval
            if isCameraAttached {
                clock.cameraBuffer(at: now)
            }
            guard isCompositing else { return }
            if let stamp = clock.displayLinkTick(at: now, targetTimestamp: now + Self.frameInterval) {
                frames.append(CompositedFrame(at: now, stamp: stamp))
            } else {
                dropped += 1
            }
        }
    }
}

/// Drives a `CompositorSimulation` through whatever order `HaishinKitStreamingSession.bringUpCapture`
/// runs the steps in, so the freeze is measured against the production order rather than a
/// hand-written one.
final class SimulatedCaptureBringUp: CaptureBringUp, @unchecked Sendable {

    private let simulation: CompositorSimulation

    init(simulation: CompositorSimulation) {
        self.simulation = simulation
    }

    func startCompositor() async {
        simulation.startCompositing()
    }

    func awaitFirstCompositedFrame() async {
        let deadline = simulation.currentTime + 0.2
        while simulation.emitted.isEmpty, simulation.currentTime < deadline {
            simulation.advanceOneFrame()
        }
    }

    func attachDevices() async throws(BroadcastFailure) {
        simulation.attachCamera()
    }

    func awaitFirstVideoInput() async {
        simulation.advanceOneFrame()
    }

    func attachStreamOutput() async {}
}

@Suite("The compositor clock HaishinKit 2.2.5 comes back from a suspension with")
struct CompositorClockModelTests {

    private static let backgroundDuration: TimeInterval = 60
    private static let observedAfterResume: TimeInterval = 2
    /// Two frame intervals of slack: what the arithmetic is allowed to be off by before it counts as
    /// a stamp in the future or a picture that stopped.
    private static let tolerance: TimeInterval = 2 * CompositorSimulation.frameInterval

    /// The bug, in the arithmetic that produces it — the device trace measured it twice: D = 11.56 s
    /// gave a freeze of 11.87 s, D = 73.47 s gave 74.34 s. Characterises HaishinKit 2.2.5's own
    /// arithmetic, so it stays green with or without our fix; re-derive it against the new
    /// Screen.swift on any HaishinKit upgrade.
    @Test("A camera attached before the display link has ticked stamps one frame a whole background into the future, and nothing else comes out until then")
    func aCameraAttachedFirstStampsOneFrameIntoTheFuture() throws {
        let simulation = CompositorSimulation(startingAt: 100)
        simulation.runUntilSuspended(forFrames: 30, thenBackgroundFor: Self.backgroundDuration)
        let resumedAt = simulation.currentTime

        // The order the session brought a pipeline up in before the fix: devices first, compositor second.
        simulation.attachCamera()
        simulation.startCompositing()
        simulation.advance(by: Self.observedAfterResume)

        #expect(simulation.emitted.count == 1, "the high-water latch let more than the one future-stamped frame through")
        let latched = try #require(simulation.emitted.first)
        #expect(
            abs(latched.stamp - (resumedAt + Self.backgroundDuration)) < Self.tolerance,
            "the one frame that got out was stamped \(latched.stamp - resumedAt) s ahead, not a background duration ahead"
        )
        #expect(
            simulation.droppedFrames == Int(Self.observedAfterResume / CompositorSimulation.frameInterval) - 1,
            "every frame after the latched one is dropped until the wall clock reaches its stamp"
        )
    }

    /// The same clock and the same suspension, ticked before the camera is attached: the frame the
    /// display link emits on its own refreshes both stale fields at the present. Characterises the
    /// library like the test above — green with or without our fix.
    @Test("A display link that ticks before the camera is attached comes back stamping the present, and the picture keeps moving")
    func aDisplayLinkThatTicksFirstKeepsThePictureMoving() throws {
        let simulation = CompositorSimulation(startingAt: 100)
        simulation.runUntilSuspended(forFrames: 30, thenBackgroundFor: Self.backgroundDuration)
        let resumedAt = simulation.currentTime

        simulation.startCompositing()
        simulation.advanceOneFrame()
        simulation.attachCamera()
        simulation.advance(by: Self.observedAfterResume)

        let first = try #require(simulation.emitted.first)
        #expect(
            abs(first.stamp - resumedAt) < Self.tolerance,
            "the first frame after the resume was stamped \(first.stamp - resumedAt) s away from the present"
        )
        #expect(simulation.longestFreeze < Self.tolerance, "the picture froze for \(simulation.longestFreeze) s")
        #expect(simulation.droppedFrames == 0, "\(simulation.droppedFrames) composited frames were dropped")
    }

    /// The lock on our own code: the order `bringUpCapture` runs, measured on the same clock.
    @Test("The order the session brings a pipeline up in leaves the compositor stamping the present")
    func theSessionsBringUpOrderLeavesTheCompositorAtThePresent() async throws {
        let simulation = CompositorSimulation(startingAt: 100)
        simulation.runUntilSuspended(forFrames: 30, thenBackgroundFor: Self.backgroundDuration)
        let resumedAt = simulation.currentTime

        try await HaishinKitStreamingSession.bringUpCapture(SimulatedCaptureBringUp(simulation: simulation))
        simulation.advance(by: Self.observedAfterResume)

        let first = try #require(simulation.emitted.first, "the compositor emitted nothing at all after this bring-up")
        #expect(
            abs(first.stamp - resumedAt) < Self.tolerance,
            "the bring-up left the compositor stamping frames \(first.stamp - resumedAt) s from the present, which is how long the picture freezes"
        )
        #expect(simulation.longestFreeze < Self.tolerance, "the picture froze for \(simulation.longestFreeze) s after this bring-up")
        #expect(simulation.droppedFrames == 0, "\(simulation.droppedFrames) composited frames were dropped after this bring-up")
    }
}
