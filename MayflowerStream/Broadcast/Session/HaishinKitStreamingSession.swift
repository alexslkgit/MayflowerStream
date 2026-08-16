//
//  HaishinKitStreamingSession.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import AVFoundation
import HaishinKit
import OSLog
import RTMPHaishinKit
import VideoToolbox

/// The steps that bring a capture pipeline up, in the order `HaishinKitStreamingSession.bringUpCapture`
/// runs them. A protocol so that order can be asserted without a camera.
protocol CaptureBringUp {
    func startCompositor() async
    func awaitFirstCompositedFrame() async
    func attachDevices() async throws(BroadcastFailure)
    func awaitFirstVideoInput() async
    func attachStreamOutput() async
}

actor HaishinKitStreamingSession: StreamingSession {

    nonisolated let events: AsyncStream<StreamingEvent>
    private nonisolated let continuation: AsyncStream<StreamingEvent>.Continuation

    private static let log = Logger(subsystem: "com.slobodianiuk.MayflowerStream", category: "broadcast")
    private static let rtmpLog = Logger(subsystem: "com.slobodianiuk.MayflowerStream", category: "rtmp")

    private struct Pipeline {
        let mixer: MediaMixer
        let connection: RTMPConnection
        let stream: RTMPStream
    }

    private var pipeline: Pipeline?
    private var statusTasks: [Task<Void, Never>] = []
    private var configuration: BroadcastConfiguration = .default

    /// Set before the first await in `startCapture`: an actor drops isolation at every await, so
    /// `pipeline == nil` alone would let a second call in while the pipeline is still building.
    private var isStartingCapture = false

    /// Bumped on every stop. `startCapture` reads it on entry and tears down what it built if the
    /// value has since changed — the only way a stop that lands mid-build is noticed.
    private(set) var captureGeneration = 0

    /// Survives a stop/start cycle; only `BroadcastController.shutDown()` clears it.
    private var overlay: (any StreamOverlay)?
    private var overlayCaption: TextScreenObject?
    private var overlayTask: Task<Void, Never>?

    private var previewViews = WeakPreviewViews<MTHKView>()

    /// `UInt8.max` is what the mixer marks its composited output with; track 0 is the camera's raw
    /// input (`MediaMixer.startRunning()`).
    private let compositedFrames = FirstFrameLatch(videoTrackId: .max)
    private let cameraInput = FirstFrameLatch(videoTrackId: 0)

    /// Gates `report(_:)` below so a self-initiated close (same RTMP codes as the server hanging
    /// up) is not reported to the user as a failure.
    private var isPublishing = false

    /// True between `publish()` and `.publishStart`. Twitch refuses a bad stream key by hanging up
    /// inside this window rather than sending `NetStream.Publish.BadName`.
    private var isPublishHandshakeInFlight = false

    private var didCloseDuringPublishHandshake = false

    init() {
        var escaped: AsyncStream<StreamingEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { escaped = $0 }
        continuation = escaped
    }

    /// `events` is read by a task that is never cancelled (see README), so `finish()` here is what
    /// stops it from hanging suspended for the rest of the process once this session is gone.
    deinit {
        continuation.finish()
    }

    // MARK: - Capture

    func startCapture(_ configuration: BroadcastConfiguration) async throws(BroadcastFailure) {
        guard pipeline == nil, !isStartingCapture else { return }
        isStartingCapture = true
        defer { isStartingCapture = false }
        // Read before the first await, so a stop arriving during any of them is visible at the end.
        let generation = captureGeneration
        self.configuration = configuration

        guard let camera = Self.captureDevice(facing: configuration.cameraFacing) else {
            throw .cameraMissing(configuration.cameraFacing)
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw .microphoneUnavailable
        }

        let connection = RTMPConnection()
        let pipeline = Pipeline(
            mixer: MediaMixer(),
            connection: connection,
            stream: RTMPStream(connection: connection)
        )

        do {
            try await pipeline.mixer.setFrameRate(configuration.frameRate)
            try await Self.applyCodecSettings(configuration, to: pipeline.stream)
        } catch {
            await tearDownCapture(pipeline)
            if let streamError = error as? RTMPStream.Error, case .unsupportedCodec = streamError {
                throw .unsupportedConfiguration(
                    reason: "This device cannot encode video in the required format."
                )
            }
            throw .encoderConfigurationFailed
        }

        // Enter .offscreen once, here, before startRunning(): a later mode flip rebuilds
        // VideoToolbox (32ARGB offscreen pool vs 420v camera output) and breaks PTS continuity.
        // Must precede startRunning() — the mixer only applies a stored mode as it starts — and
        // the screen size below must too, or the first frames go out at the library's default
        // 1280x720 and force the same rebuild. `setFrameRate` above stays in front of the mode as
        // well — the mixer reads its stored rate into the display link as it starts. The display link
        // is all it reaches now: the camera is attached after the compositor is up, so it runs at
        // HaishinKit's own default, which is the 30 fps `BroadcastConfiguration.default` asks for. A
        // configuration with any other rate would need `setFrameRate` repeated after the attach.
        var videoSettings = await pipeline.mixer.videoMixerSettings
        videoSettings.mode = .offscreen
        await pipeline.mixer.setVideoMixerSettings(videoSettings)
        let mixer = pipeline.mixer
        let videoSize = configuration.videoSize
        await Task { @ScreenActor in mixer.screen.size = videoSize }.value

        do {
            try await Self.bringUpCapture(
                SessionCaptureBringUp(session: self, pipeline: pipeline, camera: camera, microphone: microphone)
            )
        } catch {
            await tearDownCapture(pipeline)
            throw error
        }

        self.pipeline = pipeline
        if let overlay {
            await installOverlay(overlay, on: pipeline)
        }
        await observeStatus(of: pipeline)

        // A stop can land during any await above, before `self.pipeline` is assigned, and would
        // otherwise find nothing to tear down while this call keeps capturing behind it.
        if generation != captureGeneration {
            await tearDownCapture(pipeline)
        }
    }

    func stopCapture() async {
        // Bumped unconditionally, so a `startCapture` still opening the camera sees it changed.
        captureGeneration += 1
        await tearDownCapture(pipeline)
    }

    /// Gives the devices back and nothing else: the connection, the stream and the status observers
    /// stay up, so the server never learns the app went away and the broadcast keeps the one RTMP
    /// session it started with.
    func suspendCapture() async {
        guard let pipeline else { return }
        await releaseDevices(of: pipeline)
    }

    /// The inverse of `suspendCapture()` — everything the pipeline kept (codec settings, the
    /// offscreen mixer mode, the screen size, the mute) is deliberately not re-applied here.
    func resumeCapture() async throws(BroadcastFailure) {
        // Read before the first await, for the same reason `startCapture` reads it.
        let generation = captureGeneration
        guard let pipeline else {
            throw .unexpected(detail: "resumeCapture called before startCapture")
        }
        guard let camera = Self.captureDevice(facing: configuration.cameraFacing) else {
            await tearDownCapture(pipeline)
            throw .cameraMissing(configuration.cameraFacing)
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            await tearDownCapture(pipeline)
            throw .microphoneUnavailable
        }
        do {
            try await Self.bringUpCapture(
                SessionCaptureBringUp(session: self, pipeline: pipeline, camera: camera, microphone: microphone)
            )
        } catch {
            // The screen offers Try again after this, and that goes through `startCapture`, which
            // builds a pipeline only when there is none — so a kept one would make the retry a
            // silent no-op over a camera that never came back.
            await tearDownCapture(pipeline)
            throw error
        }

        // A stop can land during any await above and would otherwise leave this mixer running
        // behind a session that already let go of it.
        if generation != captureGeneration {
            await tearDownCapture(pipeline)
        }
    }

    /// What the server is holding, read from the library rather than from what the app last did: a
    /// connection that died while the app was away took the publish with it.
    func isStillPublishing() async -> Bool {
        guard let pipeline else { return false }
        let isConnected = await pipeline.connection.connected
        let readyState = await pipeline.stream.readyState
        return Self.isHeldByServer(isConnected: isConnected, readyState: readyState)
    }

    /// `connected` on its own is not an answer: after a background stay the library reported it true
    /// over a socket the system had already reclaimed, with the stream's `readyState` still `.idle`.
    /// Only a stream that reached `.publishing` is a broadcast the server is holding; trusting the
    /// connection alone puts Online over a stream nothing goes out of.
    static func isHeldByServer(isConnected: Bool, readyState: StreamReadyState) -> Bool {
        isConnected && readyState == .publishing
    }

    /// The audio session must be up before the mixer takes the devices, and the camera before the
    /// microphone — `startCapture` relies on both, and so does the return from the background.
    private func attachDevices(
        camera: sending AVCaptureDevice,
        microphone: sending AVCaptureDevice,
        to pipeline: Pipeline
    ) async throws(BroadcastFailure) {
        do {
            try Self.activateAudioSession()
        } catch {
            throw .audioSessionUnavailable
        }
        do {
            try await pipeline.mixer.attachVideo(camera)
        } catch {
            throw .cameraUnavailable
        }
        do {
            try await pipeline.mixer.attachAudio(microphone)
        } catch {
            throw .microphoneUnavailable
        }
    }

    /// The compositor measures every camera buffer against the display link's last `targetTimestamp`,
    /// and only a tick refreshes that field — `Screen.reset()` clears neither `targetTimestamp` nor
    /// the presentation-timestamp high-water mark. A buffer that arrives before the link has ticked is
    /// therefore measured against a timestamp from before the app was suspended, so the compositor
    /// stamps its next frame a whole background duration into the future, latches that stamp as its
    /// high-water mark, and the high-water check in the display-link tick then silently drops every
    /// frame until the wall clock catches up — the frozen preview. Starting the compositor and letting
    /// it draw one frame refreshes both fields at the present before the camera can be measured
    /// against them.
    static func bringUpCapture(_ steps: sending some CaptureBringUp) async throws(BroadcastFailure) {
        await steps.startCompositor()
        await steps.awaitFirstCompositedFrame()
        try await steps.attachDevices()
        await steps.awaitFirstVideoInput()
        await steps.attachStreamOutput()
    }

    /// Binds the bring-up steps to one pipeline and the devices this bring-up is for; every step
    /// hops back onto the session.
    private struct SessionCaptureBringUp: CaptureBringUp {
        let session: HaishinKitStreamingSession
        let pipeline: Pipeline
        /// `AVCaptureDevice` is not `Sendable`; both devices are handed to the mixer on the session's
        /// own executor and touched nowhere else — the claim `attachDevices` already makes with
        /// `sending`. Without this the compiler reads them as task-isolated parts of a `sending`
        /// value and refuses to pass them on.
        nonisolated(unsafe) let camera: AVCaptureDevice
        nonisolated(unsafe) let microphone: AVCaptureDevice

        func startCompositor() async {
            await session.startCompositor(of: pipeline)
        }

        func awaitFirstCompositedFrame() async {
            await session.awaitFirstCompositedFrame()
        }

        func attachDevices() async throws(BroadcastFailure) {
            try await session.attachDevices(camera: camera, microphone: microphone, to: pipeline)
        }

        func awaitFirstVideoInput() async {
            await session.waitForFirstVideoInput()
        }

        func attachStreamOutput() async {
            await session.attachStreamOutput(of: pipeline)
        }
    }

    private func startCompositor(of pipeline: Pipeline) async {
        for view in previewViews.views {
            await pipeline.mixer.addOutput(view)
        }
        compositedFrames.arm()
        cameraInput.arm()
        await pipeline.mixer.addOutput(compositedFrames)
        await pipeline.mixer.addOutput(cameraInput)
        await pipeline.mixer.startRunning()
    }

    /// Bounded, because a compositor that never draws must still leave the caller with a stream it
    /// can publish.
    private func awaitFirstCompositedFrame() async {
        let limit: Duration = .milliseconds(200)
        let deadline = ContinuousClock.now + limit
        while !compositedFrames.hasSeenFrame, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard !compositedFrames.hasSeenFrame else { return }
        Self.log.notice(
            "the compositor drew no frame within \(limit.description, privacy: .public); attaching the camera anyway"
        )
    }

    private func attachStreamOutput(of pipeline: Pipeline) async {
        await pipeline.mixer.addOutput(pipeline.stream)
    }

    /// The offscreen compositor draws at the frame rate from the moment the mixer starts, so a stream
    /// attached before the camera's first buffer encodes and sends background colour for as long as
    /// the camera takes to wake — a fifth of a second of black at the top of every broadcast and every
    /// return from the background. Bounded, because a camera that never delivers must still leave the
    /// caller with a stream it can publish.
    ///
    /// Waits on the latch armed in `startCompositor(of:)` rather than on `mixer.videoInputFormats`:
    /// the formats are a level that survives a suspension, so from the second bring-up onwards they
    /// answer before the camera has delivered anything.
    private func waitForFirstVideoInput() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !cameraInput.hasSeenFrame, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func tearDownCapture(_ pipeline: Pipeline?) async {
        isPublishing = false
        isPublishHandshakeInFlight = false
        overlayTask?.cancel()
        overlayTask = nil
        overlayCaption = nil
        for task in statusTasks { task.cancel() }
        statusTasks.removeAll()
        self.pipeline = nil

        guard let pipeline else { return }
        await releaseDevices(of: pipeline)
        // SwiftUI rebuilds preview views on the next capture; keeping stale ones here would leak
        // one per stop.
        previewViews.removeAll()
    }

    private func releaseDevices(of pipeline: Pipeline) async {
        await pipeline.mixer.stopRunning()
        // Always detach, even if the mixer never started: it holds the camera/mic until told
        // otherwise, dropping the mixer alone does not release them.
        try? await pipeline.mixer.attachVideo(nil)
        try? await pipeline.mixer.attachAudio(nil)
        await pipeline.mixer.removeOutput(pipeline.stream)
        for view in previewViews.views {
            await pipeline.mixer.removeOutput(view)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func switchCamera(to facing: CameraFacing) async throws(BroadcastFailure) {
        guard let pipeline else { return }
        guard let camera = Self.captureDevice(facing: facing) else {
            throw .cameraMissing(facing)
        }
        do {
            try await pipeline.mixer.attachVideo(camera)
        } catch {
            throw .cameraUnavailable
        }
        configuration.cameraFacing = facing
    }

    func setMicrophoneMuted(_ isMuted: Bool) async -> Bool {
        guard let pipeline else { return isMuted }
        var settings = await pipeline.mixer.audioMixerSettings
        settings.isMuted = isMuted
        await pipeline.mixer.setAudioMixerSettings(settings)
        return await pipeline.mixer.audioMixerSettings.isMuted
    }

    // MARK: - Publishing

    func startPublishing(to endpoint: StreamEndpoint) async throws(BroadcastFailure) {
        guard let pipeline else {
            throw .unexpected(detail: "startPublishing called before startCapture")
        }
        do {
            didCloseDuringPublishHandshake = false
            _ = try await pipeline.connection.connect(endpoint.connectURL)
            isPublishHandshakeInFlight = true
            _ = try await pipeline.stream.publish(endpoint.streamKey)
            isPublishHandshakeInFlight = false
            isPublishing = true
        } catch {
            isPublishing = false
            // Must be read before `close()` below: our own close reaches the status handler as the
            // same code as the peer hanging up, and would overwrite this otherwise.
            let closedDuringHandshake = didCloseDuringPublishHandshake
            isPublishHandshakeInFlight = false
            didCloseDuringPublishHandshake = false
            // `connect()` refuses outright while the connection is still open, so a failed attempt
            // must close both before returning or every retry fails for the wrong reason.
            _ = try? await pipeline.stream.close()
            try? await pipeline.connection.close()
            let failure = Self.publishFailure(from: error, closedDuringHandshake: closedDuringHandshake)
            Self.log.error("publishing failed: \(failure.diagnosticDescription, privacy: .public)")
            throw failure
        }
    }

    func stopPublishing() async {
        isPublishing = false
        isPublishHandshakeInFlight = false
        guard let pipeline else { return }
        _ = try? await pipeline.stream.close()
        try? await pipeline.connection.close()
    }

    // MARK: - Overlay

    func setOverlay(_ overlay: (any StreamOverlay)?) async {
        self.overlay = overlay
        overlayTask?.cancel()
        overlayTask = nil

        guard let pipeline else { return }
        guard let overlay else {
            await removeOverlay(from: pipeline)
            return
        }
        await installOverlay(overlay, on: pipeline)
    }

    /// Mixer is already compositing (see `startCapture`); this just adds a child to that screen.
    private func installOverlay(_ overlay: any StreamOverlay, on pipeline: Pipeline) async {
        let mixer = pipeline.mixer
        let size = configuration.videoSize
        let placement = overlay.placement
        let text = overlay.text(at: Date())
        let caption: TextScreenObject
        if let existing = overlayCaption {
            caption = existing
        } else {
            caption = await Task { @ScreenActor in TextScreenObject() }.value
            overlayCaption = caption
        }

        await Task { @ScreenActor in
            caption.horizontalAlignment = placement.horizontalAlignment
            caption.verticalAlignment = placement.verticalAlignment
            let margins = placement.layoutMargins(in: size)
            caption.layoutMargin = .init(top: margins.top, left: margins.left, bottom: margins.bottom, right: margins.right)
            caption.string = text
            try? mixer.screen.addChild(caption)
        }.value

        guard let interval = overlay.refreshInterval else { return }
        overlayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await redrawOverlay()
            }
        }
    }

    private func redrawOverlay() async {
        guard let overlay, let caption = overlayCaption else { return }
        let text = overlay.text(at: Date())
        await Task { @ScreenActor in caption.string = text }.value
    }

    /// Leaves the mixer compositing an empty screen — dropping back to passthrough would trigger
    /// the same rebuild `.offscreen` above exists to avoid.
    private func removeOverlay(from pipeline: Pipeline) async {
        let mixer = pipeline.mixer
        if let caption = overlayCaption {
            await Task { @ScreenActor in mixer.screen.removeChild(caption) }.value
        }
        overlayCaption = nil
    }

    func currentStatistics() async -> StreamStatistics {
        guard let pipeline else { return StreamStatistics(configured: configuration) }
        let video = await pipeline.stream.videoSettings
        let audio = await pipeline.stream.audioSettings
        return StreamStatistics(
            configured: configuration,
            appliedVideoSize: video.videoSize,
            appliedVideoBitRate: video.bitRate,
            // The encoder's actual format isn't exposed directly; the profile string is, and an
            // HEVC profile is what switches it.
            appliedVideoCodec: video.profileLevel.contains("HEVC") ? "HEVC" : "H.264",
            appliedAudioBitRate: audio.bitRate,
            appliedAudioCodec: audio.format == .aac ? "AAC" : String(describing: audio.format),
            currentFrameRate: Int(await pipeline.stream.currentFPS),
            currentBytesPerSecond: await pipeline.stream.info.currentBytesPerSecond
        )
    }

    // MARK: - Codec settings

    private static func applyCodecSettings(
        _ configuration: BroadcastConfiguration,
        to stream: RTMPStream
    ) async throws {
        var video = await stream.videoSettings
        video.videoSize = configuration.videoSize
        video.bitRate = configuration.videoBitRate
        // H.264 is required by the task. Setting an H.264 profile is also what keeps the encoder
        // out of HEVC — the library picks its format from this string.
        video.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
        // High profile would otherwise turn B-frames on, and a picture the encoder has to hold back
        // to reorder is a picture the viewer waits for. Set here, with the rest: the library rebuilds
        // the compression session when this changes, so it must be in force before the first frame.
        video.allowFrameReordering = false
        video.maxKeyFrameIntervalDuration = Int32(configuration.keyFrameIntervalSeconds)
        video.expectedFrameRate = configuration.frameRate
        try await stream.setVideoSettings(video)

        var audio = await stream.audioSettings
        audio.format = .aac
        audio.bitRate = configuration.audioBitRate
        try await stream.setAudioSettings(audio)
    }

    // MARK: - Status

    /// `connection.status`, `stream.status` and `mixer.isInterputted` are computed properties that
    /// re-arm on every read, disconnecting the previous reader — so these three must be read
    /// exactly once, here, per pipeline.
    private func observeStatus(of pipeline: Pipeline) async {
        guard statusTasks.isEmpty else { return }

        let connectionStatus = await pipeline.connection.status
        let streamStatus = await pipeline.stream.status
        let interruptions = await pipeline.mixer.isInterputted

        statusTasks = [
            Task { [weak self] in
                for await status in connectionStatus {
                    await self?.handleConnectionStatus(status)
                }
            },
            Task { [weak self] in
                for await status in streamStatus {
                    await self?.handleStreamStatus(status)
                }
            },
            Task { [weak self] in
                for await isInterrupted in interruptions {
                    await self?.handleCaptureInterruption(isInterrupted)
                }
            },
        ]
    }

    /// Capture session interruption (e.g. a phone call), not the connection — nothing on the wire
    /// changes while it lasts, so this is the only signal that the outgoing picture has frozen.
    private func handleCaptureInterruption(_ isInterrupted: Bool) {
        Self.log.notice("capture interrupted: \(isInterrupted, privacy: .public)")
        continuation.yield(isInterrupted ? .captureInterrupted : .captureResumed)
    }

    private func handleConnectionStatus(_ status: RTMPStatus) {
        Self.rtmpLog.debug("connection status: \(status.code, privacy: .public) — \(status.description, privacy: .public)")
        switch RTMPConnection.Code(rawValue: status.code) {
        case .connectSuccess:
            // The transport is up. Being live is a stream-level fact, so nothing is reported here.
            break
        case .connectClosed, .connectAppshutdown, .connectNetworkChange:
            connectionClosed()
        case .connectIdleTimeOut:
            report(.connectionTimedOut)
        case .connectFailed, .connectRejected, .connectInvalidApp:
            report(.serverRefused)
        default:
            break
        }
    }

    private func handleStreamStatus(_ status: RTMPStatus) {
        Self.rtmpLog.debug("stream status: \(status.code, privacy: .public) — \(status.description, privacy: .public)")
        switch RTMPStream.Code(rawValue: status.code) {
        case .publishStart:
            // From here a close is a lost broadcast, not a refused key — see `connectionClosed()`.
            isPublishHandshakeInFlight = false
            continuation.yield(.publishing)
        case .publishBadName:
            // Never seen from Twitch (it hangs up instead), kept for servers that do report it.
            report(.streamKeyRejected)
        case .connectRejected:
            report(.serverRefused)
        case .connectClosed, .connectFailed, .failed:
            connectionClosed()
        case .unpublishSuccess:
            // We asked for this, or the server acknowledged our close. Not a failure.
            break
        default:
            break
        }
    }

    /// Inside the publish handshake, a close means Twitch refused the stream key; the in-flight
    /// `publish()` call reports it once its own timeout fires. Anywhere else, it's a dropped
    /// broadcast.
    private func connectionClosed() {
        guard isPublishHandshakeInFlight else {
            report(.connectionLost)
            return
        }
        didCloseDuringPublishHandshake = true
    }

    /// No-op unless there was a broadcast to drop; reconnecting is the controller's call.
    private func report(_ failure: BroadcastFailure) {
        guard isPublishing else { return }
        isPublishing = false
        Self.log.error("the broadcast dropped: \(failure.diagnosticDescription, privacy: .public)")
        continuation.yield(.disconnected(failure))
    }

    // MARK: - Translating the library's errors

    /// A close during the publish handshake is reported as a refused stream key rather than the
    /// timeout `publish()` would otherwise see — a real network drop in that same window is
    /// misclassified too, but "check your key" costs a retry while "check your internet" on a bad
    /// key loses the broadcast entirely.
    static func publishFailure(from error: any Error, closedDuringHandshake: Bool) -> BroadcastFailure {
        closedDuringHandshake ? .streamKeyRejected : failure(from: error)
    }

    private static func failure(from error: any Error) -> BroadcastFailure {
        switch error {
        case let error as RTMPStream.Error: failure(from: error)
        case let error as RTMPConnection.Error: failure(from: error)
        default: .unexpected(detail: String(describing: error))
        }
    }

    private static func failure(from error: RTMPConnection.Error) -> BroadcastFailure {
        switch error {
        case .connectionTimedOut, .requestTimedOut:
            .connectionTimedOut
        case .socketErrorOccurred:
            .serverUnreachable
        case .requestFailed(let response):
            failure(fromStatusCode: response.status?.code) ?? .serverRefused
        case .invalidState, .unsupportedCommand:
            .unexpected(detail: String(describing: error))
        }
    }

    private static func failure(from error: RTMPStream.Error) -> BroadcastFailure {
        switch error {
        case .requestTimedOut:
            .connectionTimedOut
        case .unsupportedCodec:
            .unsupportedConfiguration(reason: "This device cannot encode video in the required format.")
        case .requestFailed(let response):
            failure(fromStatusCode: response.status?.code) ?? .serverRefused
        case .invalidState:
            .unexpected(detail: String(describing: error))
        }
    }

    private static func failure(fromStatusCode code: String?) -> BroadcastFailure? {
        guard let code else { return nil }
        if RTMPStream.Code(rawValue: code) == .publishBadName { return .streamKeyRejected }
        switch RTMPConnection.Code(rawValue: code) {
        case .connectRejected, .connectInvalidApp, .connectFailed: return .serverRefused
        case .connectIdleTimeOut: return .connectionTimedOut
        case .connectClosed: return .connectionLost
        default: return nil
        }
    }

    // MARK: - Devices

    private static func captureDevice(facing: CameraFacing) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: facing == .front ? .front : .back
        ).devices.first
    }

    private static func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            // allowBluetoothHFP has been available since iOS 1.0 (renamed API), no availability
            // check needed for a 17.0 deployment target.
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)
    }

    // MARK: - Preview

    private func attach(previewView: MTHKView) async {
        guard !previewViews.contains(previewView) else { return }
        previewViews.append(previewView)
        if let pipeline {
            await pipeline.mixer.addOutput(previewView)
        }
    }
}

@ScreenActor
private extension StreamOverlayPlacement {
    /// `.right` hangs the caption `layoutMargin.right` from the right edge — see `layoutMargins(in:)`
    /// for how that margin is sized to survive the preview crop.
    var horizontalAlignment: ScreenObject.HorizontalAlignment {
        switch self {
        case .topTrailing: .right
        }
    }

    var verticalAlignment: ScreenObject.VerticalAlignment {
        switch self {
        case .topTrailing: .top
        }
    }
}

extension HaishinKitStreamingSession: MTHKViewRepresentable.PreviewSource {
    nonisolated func connect(to view: MTHKView) {
        Task { await attach(previewView: view) }
    }
}

/// The views the mixer draws the preview into, each held weakly. SwiftUI builds a new `MTHKView`
/// every time the screen leaves the preview — the restore placeholder does that on every background
/// round trip — and hands it here, so a list that held them strongly kept every Metal view ever built
/// alive and fed: three of them after two round trips.
/// Generic over the element so the rule can be pinned without a Metal device.
struct WeakPreviewViews<View: AnyObject> {

    private struct Box {
        weak var view: View?
    }

    private var boxes: [Box] = []

    /// The views something else is still showing; the ones SwiftUI released are dropped here.
    var views: [View] {
        boxes.compactMap(\.view)
    }

    func contains(_ view: View) -> Bool {
        boxes.contains { $0.view === view }
    }

    mutating func append(_ view: View) {
        boxes.removeAll { $0.view == nil }
        boxes.append(Box(view: view))
    }

    mutating func removeAll() {
        boxes.removeAll()
    }
}

/// The first frame to reach it after `arm()`, latched. The bring-up needs an edge — "a frame has
/// arrived since I asked" — and the mixer offers only levels: `videoInputFormats` stays set across a
/// suspend, so it answers yes before the camera has delivered anything.
/// `@unchecked Sendable` because the one mutable field is read and written under `lock`.
final class FirstFrameLatch: MediaMixerOutput, @unchecked Sendable {
    let videoTrackId: UInt8?
    let audioTrackId: UInt8? = nil

    private let lock = NSLock()
    private var hasFrame = false

    init(videoTrackId: UInt8) {
        self.videoTrackId = videoTrackId
    }

    var hasSeenFrame: Bool {
        lock.withLock { hasFrame }
    }

    func arm() {
        lock.withLock { hasFrame = false }
    }

    func latchFrame() {
        lock.withLock { hasFrame = true }
    }

    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        latchFrame()
    }

    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {}

    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}
}
