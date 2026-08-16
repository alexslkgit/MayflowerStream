//
//  CaptureBringUpOrderTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 16.08.2026.
//

import Foundation
import Testing

@testable import MayflowerStream

enum CaptureBringUpStep: String, Sendable {
    case startCompositor
    case awaitFirstCompositedFrame
    case attachDevices
    case awaitFirstVideoInput
    case attachStreamOutput
}

/// Records the order the steps are run in and does nothing else — the only way to see a bring-up
/// order on a simulator, which has no camera to bring up.
/// `@unchecked Sendable` because the one mutable field is read and written under `lock`.
final class RecordingCaptureBringUp: CaptureBringUp, @unchecked Sendable {

    private let lock = NSLock()
    private var recorded: [CaptureBringUpStep] = []

    var steps: [CaptureBringUpStep] {
        lock.withLock { recorded }
    }

    func startCompositor() async {
        record(.startCompositor)
    }

    func awaitFirstCompositedFrame() async {
        record(.awaitFirstCompositedFrame)
    }

    func attachDevices() async throws(BroadcastFailure) {
        record(.attachDevices)
    }

    func awaitFirstVideoInput() async {
        record(.awaitFirstVideoInput)
    }

    func attachStreamOutput() async {
        record(.attachStreamOutput)
    }

    private func record(_ step: CaptureBringUpStep) {
        lock.withLock { recorded.append(step) }
    }
}

/// `startCapture` and `resumeCapture` both hand their pipeline to `bringUpCapture` and do nothing of
/// their own with the devices, so this order is the order of both.
@Suite("The order a capture pipeline is brought up in")
struct CaptureBringUpOrderTests {

    @Test("The compositor is running, and has drawn a frame, before the camera is ever attached")
    func theCompositorIsUpBeforeTheCameraIsAttached() async throws {
        let recorder = RecordingCaptureBringUp()

        try await HaishinKitStreamingSession.bringUpCapture(recorder)

        // Each step is here for a reason the next one depends on: the display link's targetTimestamp
        // is refreshed only by a tick, the camera must be measured against a fresh one, and the
        // encoder must not be attached to a compositor that is still drawing an empty screen.
        #expect(
            recorder.steps == [
                .startCompositor,
                .awaitFirstCompositedFrame,
                .attachDevices,
                .awaitFirstVideoInput,
                .attachStreamOutput,
            ],
            "the pipeline was brought up as \(recorder.steps.map(\.rawValue))"
        )
    }
}

/// The wait between attaching the camera and attaching the encoder has to be an edge — a buffer that
/// arrived since we asked — because every level the mixer offers (`videoInputFormats`) survives a
/// suspension and answers yes before the camera has delivered anything.
@Suite("What the first-video-input wait is waiting for")
struct FirstFrameLatchTests {

    @Test("A latch that has not been armed has seen nothing")
    func anUnarmedLatchHasSeenNothing() {
        #expect(FirstFrameLatch(videoTrackId: 0).hasSeenFrame == false)
    }

    @Test("Arming forgets the frames of the broadcast before the suspension")
    func armingForgetsEarlierFrames() {
        let latch = FirstFrameLatch(videoTrackId: 0)
        latch.latchFrame()
        #expect(latch.hasSeenFrame, "the latch did not see the frame it was given")

        latch.arm()

        #expect(
            latch.hasSeenFrame == false,
            "the latch still answers with a frame from before the suspension, which is the level bug it exists to avoid"
        )
    }
}
