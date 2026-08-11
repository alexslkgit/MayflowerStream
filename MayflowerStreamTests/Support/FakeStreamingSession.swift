import Foundation

@testable import MayflowerStream

/// A streaming session with no camera, no encoder and no server, driven entirely by the test.
/// This is the reason `StreamingSession` exists: every state transition and every error path in
/// `BroadcastController` can be exercised on a machine that has none of the hardware.
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

    // What actually happened.
    private(set) var captureStartCount = 0
    private(set) var captureStopCount = 0
    private(set) var publishStartCount = 0
    private(set) var publishStopCount = 0
    private(set) var facing: CameraFacing = .back
    private(set) var isMicrophoneMuted = false
    var configuration: BroadcastConfiguration = .default

    init() {
        var escaped: AsyncStream<StreamingEvent>.Continuation!
        events = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    /// Pretend the server said something.
    nonisolated func emit(_ event: StreamingEvent) {
        continuation.yield(event)
    }

    // MARK: - StreamingSession

    func startCapture(_ configuration: BroadcastConfiguration) async throws(BroadcastFailure) {
        captureStartCount += 1
        if let captureFailure { throw captureFailure }
        self.configuration = configuration
        facing = configuration.cameraFacing
    }

    func stopCapture() async {
        captureStopCount += 1
    }

    func switchCamera(to facing: CameraFacing) async throws(BroadcastFailure) {
        if let switchCameraFailure { throw switchCameraFailure }
        self.facing = facing
    }

    func setMicrophoneMuted(_ isMuted: Bool) async {
        isMicrophoneMuted = isMuted
    }

    func startPublishing(to endpoint: StreamEndpoint) async throws(BroadcastFailure) {
        publishStartCount += 1
        if !publishFailures.isEmpty, let failure = publishFailures.removeFirst() {
            throw failure
        }
    }

    func stopPublishing() async {
        publishStopCount += 1
    }

    func currentStatistics() async -> StreamStatistics {
        StreamStatistics(
            configured: configuration,
            actualVideoBitRate: configuration.videoBitRate,
            actualAudioBitRate: configuration.audioBitRate,
            actualVideoSize: configuration.videoSize
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
