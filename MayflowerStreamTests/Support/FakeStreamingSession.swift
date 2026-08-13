//
//  FakeStreamingSession.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation

@testable import MayflowerStream

/// A streaming session with no camera, no encoder and no server, driven entirely by the test, so
/// every state transition and every error path in `BroadcastController` can be exercised on a
/// machine that has none of the hardware.
@MainActor
final class FakeStreamingSession: StreamingSession {

    nonisolated let events: AsyncStream<StreamingEvent>
    private nonisolated let continuation: AsyncStream<StreamingEvent>.Continuation

    // What the test wants to happen.
    var captureFailure: BroadcastFailure?
    var switchCameraFailure: BroadcastFailure?
    /// Consumed one per `startPublishing` call. `nil` means that call succeeds. When the queue runs
    /// out, every further call succeeds.
    var publishFailures: [BroadcastFailure?] = []
    /// Make `startCapture`, `startPublishing` and `switchCamera` suspend, so a test can act while
    /// one of them is in flight.
    var captureDelay: Duration = .zero
    var publishDelay: Duration = .zero
    var switchCameraDelay: Duration = .zero

    // What actually happened.
    private(set) var captureStartCount = 0
    private(set) var captureStopCount = 0
    private(set) var publishStartCount = 0
    private(set) var publishStopCount = 0
    private(set) var switchCameraCount = 0
    private(set) var facing: CameraFacing = .back
    private(set) var isMicrophoneMuted = false
    private(set) var overlay: (any StreamOverlay)?
    var configuration: BroadcastConfiguration = .default

    /// The one library rule that matters to the state machine: RTMP refuses to connect while a
    /// connection is already open. Modelling it here is what makes "a failed attempt leaves
    /// nothing open" — the contract written on `StreamingSession.startPublishing` — testable.
    private(set) var isConnectionOpen = false

    init() {
        var escaped: AsyncStream<StreamingEvent>.Continuation!
        events = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    /// Pretend the server said something.
    ///
    /// A drop normally takes the connection with it. `closingConnection: false` is the other case
    /// — the publish ends while the socket stays up — which is where a session that does not clean
    /// up after itself makes every following attempt fail for the wrong reason.
    func emit(_ event: StreamingEvent, closingConnection: Bool = true) {
        if case .disconnected = event, closingConnection { isConnectionOpen = false }
        continuation.yield(event)
    }

    // MARK: - StreamingSession

    func startCapture(_ configuration: BroadcastConfiguration) async throws(BroadcastFailure) {
        captureStartCount += 1
        if captureDelay != .zero { try? await Task.sleep(for: captureDelay) }
        if let captureFailure { throw captureFailure }
        self.configuration = configuration
        facing = configuration.cameraFacing
    }

    func stopCapture() async {
        captureStopCount += 1
    }

    func switchCamera(to facing: CameraFacing) async throws(BroadcastFailure) {
        switchCameraCount += 1
        if switchCameraDelay != .zero { try? await Task.sleep(for: switchCameraDelay) }
        if let switchCameraFailure { throw switchCameraFailure }
        self.facing = facing
    }

    func setMicrophoneMuted(_ isMuted: Bool) async -> Bool {
        isMicrophoneMuted = isMuted
        return isMuted
    }

    func startPublishing(to endpoint: StreamEndpoint) async throws(BroadcastFailure) {
        publishStartCount += 1
        if isConnectionOpen {
            isConnectionOpen = false
            throw .unexpected(detail: "the connection was still open")
        }
        isConnectionOpen = true
        if publishDelay != .zero { try? await Task.sleep(for: publishDelay) }
        if !publishFailures.isEmpty, let failure = publishFailures.removeFirst() {
            isConnectionOpen = false
            throw failure
        }
    }

    func stopPublishing() async {
        publishStopCount += 1
        isConnectionOpen = false
    }

    func setOverlay(_ overlay: (any StreamOverlay)?) async {
        self.overlay = overlay
    }

    func currentStatistics() async -> StreamStatistics {
        StreamStatistics(
            configured: configuration,
            appliedVideoSize: configuration.videoSize,
            appliedVideoBitRate: configuration.videoBitRate,
            appliedVideoCodec: BroadcastConfiguration.videoCodec,
            appliedAudioBitRate: configuration.audioBitRate,
            appliedAudioCodec: BroadcastConfiguration.audioCodec,
            currentFrameRate: Int(configuration.frameRate)
        )
    }
}

/// Answers permission requests without a device.
@MainActor
final class StubMediaPermissions: MediaPermissions {
    var camera: MediaPermissionOutcome
    var microphone: MediaPermissionOutcome
    private(set) var requested: [MediaKind] = []

    init(camera: MediaPermissionOutcome = .granted, microphone: MediaPermissionOutcome = .granted) {
        self.camera = camera
        self.microphone = microphone
    }

    func requestAccess(to kind: MediaKind) async -> MediaPermissionOutcome {
        requested.append(kind)
        return kind == .camera ? camera : microphone
    }
}

/// Waits for something the controller does on its own — an event it is draining in the background,
/// or a reconnection attempt — instead of guessing how many `Task.yield()`s it will take.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    throw WaitTimedOut(description: description)
}

struct WaitTimedOut: Error, CustomStringConvertible {
    let description: String
}
