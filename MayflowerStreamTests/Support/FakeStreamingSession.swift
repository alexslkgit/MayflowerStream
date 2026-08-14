//
//  FakeStreamingSession.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation

@testable import MayflowerStream

/// A streaming session with no camera, no encoder and no server, driven entirely by the test, so every state transition and error path in `BroadcastController` can be exercised without hardware.
@MainActor
final class FakeStreamingSession: StreamingSession {

    nonisolated let events: AsyncStream<StreamingEvent>
    private nonisolated let continuation: AsyncStream<StreamingEvent>.Continuation

    // What the test wants to happen.
    var captureFailure: BroadcastFailure?
    var switchCameraFailure: BroadcastFailure?
    var publishFailures: [BroadcastFailure?] = []
    var currentBytesPerSecond: Int?
    var captureDelay: Duration = .zero
    var publishDelay: Duration = .zero
    var stopPublishingDelay: Duration = .zero
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

    /// RTMP refuses to connect while a connection is already open — modelling that is what makes the "a failed attempt leaves nothing open" contract on `StreamingSession.startPublishing` testable.
    private(set) var isConnectionOpen = false

    init() {
        var escaped: AsyncStream<StreamingEvent>.Continuation!
        events = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    /// `closingConnection: false` models a drop that ends the publish but leaves the socket up — the case where a session that does not clean up makes every following attempt fail for the wrong reason.
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
        // Closed at the end, not the start, because that is when RTMP closes it: a publish attempted mid-goodbye must hit the still-open connection, as it would on the wire.
        if stopPublishingDelay != .zero { try? await Task.sleep(for: stopPublishingDelay) }
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
            currentFrameRate: Int(configuration.frameRate),
            currentBytesPerSecond: currentBytesPerSecond
        )
    }
}

/// A connectivity monitor with no network behind it: the test says when the path goes and comes back, including the current-state update every real monitor sends the moment it starts.
@MainActor
final class FakeConnectivityMonitor: ConnectivityMonitor {

    /// True while somebody is iterating the updates — a real `NWPathMonitor` lives exactly as long as its stream is being read.
    private(set) var isWatching = false
    private var continuation: AsyncStream<Bool>.Continuation?

    func updates() async -> AsyncStream<Bool> {
        AsyncStream { continuation in
            self.continuation = continuation
            isWatching = true
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stopWatching() }
            }
        }
    }

    func send(isSatisfied: Bool) {
        continuation?.yield(isSatisfied)
    }

    private func stopWatching() {
        isWatching = false
        continuation = nil
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

/// Waits for something the controller does on its own instead of guessing how many `Task.yield()`s it will take.
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
