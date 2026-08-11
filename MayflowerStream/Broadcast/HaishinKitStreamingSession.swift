import AVFoundation
import HaishinKit
import RTMPHaishinKit
import VideoToolbox

/// The real streaming session: HaishinKit 2.2.5 behind `StreamingSession`.
///
/// Everything the library exposes is actor-isolated, which is why this type is an actor too — it
/// is the only place in the app that has to `await` its way through a media pipeline, and keeping
/// that inside one file is most of the reason the protocol exists.
///
/// **Nothing is built until `startCapture`.** Creating this object allocates an event stream and
/// nothing else. That is not tidiness: `RTMPStream.init` starts a task that registers itself with
/// its connection, so building the pipeline when the screen appears would leave live objects
/// behind every time SwiftUI re-evaluated the view, and would open the media stack without the
/// user having asked for it. The pipeline is created on the explicit tap and destroyed on
/// `stopCapture`.
///
/// The pipeline is: `MediaMixer` owns the camera and the microphone, `RTMPStream` is registered as
/// one of the mixer's outputs and encodes what the mixer produces, and `RTMPConnection` carries it
/// to the server. The preview view is registered as an output of the *mixer*, not of the stream,
/// so it shows what the camera sees whether or not anything is being published. That is why a
/// preview can be live while the status panel says Offline.
///
/// **Where a visual overlay would go.** Frames reach the encoder only through
/// `MediaMixer.addOutput`. Drawing a clock onto the outgoing picture means adding a
/// `MediaMixerOutput` that receives each `CMSampleBuffer`, composites onto it and appends the
/// result to the stream — one type, added here, with nothing above this file changing.
actor HaishinKitStreamingSession: StreamingSession {

    nonisolated let events: AsyncStream<StreamingEvent>
    private nonisolated let continuation: AsyncStream<StreamingEvent>.Continuation

    /// The media stack. Nil until the user starts the camera, and nil again after they stop it.
    private struct Pipeline {
        let mixer: MediaMixer
        let connection: RTMPConnection
        let stream: RTMPStream
    }

    private var pipeline: Pipeline?
    private var statusTasks: [Task<Void, Never>] = []
    private var configuration: BroadcastConfiguration = .default

    /// Preview views SwiftUI has created. They are attached to the mixer when there is one, and
    /// remembered when there is not, so the preview comes back if capture is restarted.
    private var previewViews: [MTHKView] = []

    /// Whether a drop should be reported. Closing the connection ourselves produces the same RTMP
    /// status codes as the server hanging up, and the user must not be told a broadcast failed
    /// when they are the one who ended it.
    private var isPublishing = false

    init() {
        var escaped: AsyncStream<StreamingEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { escaped = $0 }
        continuation = escaped
    }

    // MARK: - Capture

    func startCapture(_ configuration: BroadcastConfiguration) async throws(BroadcastFailure) {
        guard pipeline == nil else { return }
        self.configuration = configuration

        guard let camera = Self.captureDevice(facing: configuration.cameraFacing) else {
            throw .cameraMissing(configuration.cameraFacing)
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw .cameraUnavailable
        }

        let connection = RTMPConnection()
        let pipeline = Pipeline(
            mixer: MediaMixer(),
            connection: connection,
            stream: RTMPStream(connection: connection)
        )

        do {
            try Self.activateAudioSession()
            try await pipeline.mixer.attachVideo(camera)
            try await pipeline.mixer.attachAudio(microphone)
            try await pipeline.mixer.setFrameRate(configuration.frameRate)
            try await Self.applyCodecSettings(configuration, to: pipeline.stream)
            await pipeline.mixer.addOutput(pipeline.stream)
            for view in previewViews {
                await pipeline.mixer.addOutput(view)
            }
            await pipeline.mixer.startRunning()
        } catch {
            // Leave nothing half-built behind: if any step failed, the whole pipeline is dropped.
            await pipeline.mixer.stopRunning()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            throw .cameraUnavailable
        }

        self.pipeline = pipeline
        await observeStatus(of: pipeline)
    }

    func stopCapture() async {
        isPublishing = false
        for task in statusTasks { task.cancel() }
        statusTasks.removeAll()

        guard let pipeline else { return }
        self.pipeline = nil

        await pipeline.mixer.stopRunning()
        try? await pipeline.mixer.attachVideo(nil)
        try? await pipeline.mixer.attachAudio(nil)
        await pipeline.mixer.removeOutput(pipeline.stream)
        for view in previewViews {
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

    func setMicrophoneMuted(_ isMuted: Bool) async {
        guard let pipeline else { return }
        var settings = await pipeline.mixer.audioMixerSettings
        settings.isMuted = isMuted
        await pipeline.mixer.setAudioMixerSettings(settings)
    }

    // MARK: - Publishing

    func startPublishing(to endpoint: StreamEndpoint) async throws(BroadcastFailure) {
        guard let pipeline else {
            throw .unexpected(detail: "startPublishing called before startCapture")
        }
        do {
            _ = try await pipeline.connection.connect(endpoint.connectURL)
            _ = try await pipeline.stream.publish(endpoint.streamKey)
            isPublishing = true
        } catch let error as RTMPStream.Error {
            throw Self.failure(from: error)
        } catch let error as RTMPConnection.Error {
            throw Self.failure(from: error)
        } catch {
            throw .unexpected(detail: String(describing: error))
        }
    }

    func stopPublishing() async {
        isPublishing = false
        guard let pipeline else { return }
        _ = try? await pipeline.stream.close()
        try? await pipeline.connection.close()
    }

    func currentStatistics() async -> StreamStatistics {
        guard let pipeline else { return StreamStatistics(configured: configuration) }
        let video = await pipeline.stream.videoSettings
        let audio = await pipeline.stream.audioSettings
        return StreamStatistics(
            configured: configuration,
            appliedVideoSize: video.videoSize,
            appliedVideoBitRate: video.bitRate,
            // The encoder's own format is not visible outside the library, but the profile it is
            // running with is, and an HEVC profile is what switches it. So this reports the codec
            // the encoder actually has rather than the one it was asked for.
            appliedVideoCodec: video.profileLevel.contains("HEVC") ? "HEVC" : "H.264",
            appliedAudioBitRate: audio.bitRate,
            appliedAudioCodec: audio.format == .aac ? "AAC" : String(describing: audio.format),
            currentFrameRate: Int(await pipeline.stream.currentFPS)
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
        video.maxKeyFrameIntervalDuration = Int32(configuration.keyFrameIntervalSeconds)
        video.expectedFrameRate = configuration.frameRate
        try await stream.setVideoSettings(video)

        var audio = await stream.audioSettings
        audio.format = .aac
        audio.bitRate = configuration.audioBitRate
        try await stream.setAudioSettings(audio)
    }

    // MARK: - Status

    /// Subscribes to both status streams **once** per pipeline.
    ///
    /// `RTMPConnection.status` and `RTMPStream.status` are computed properties that install a new
    /// continuation on every read, which silently disconnects whoever was reading before. Reading
    /// either of them a second time anywhere would make this listener go quiet with no error at
    /// all, so the tasks are created here and nowhere else.
    private func observeStatus(of pipeline: Pipeline) async {
        guard statusTasks.isEmpty else { return }

        let connectionStatus = await pipeline.connection.status
        let streamStatus = await pipeline.stream.status

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
        ]
    }

    private func handleConnectionStatus(_ status: RTMPStatus) {
        switch RTMPConnection.Code(rawValue: status.code) {
        case .connectSuccess:
            // The transport is up. Being live is a stream-level fact, so nothing is reported here.
            break
        case .connectClosed, .connectAppshutdown, .connectNetworkChange:
            report(.connectionLost)
        case .connectIdleTimeOut:
            report(.connectionTimedOut)
        case .connectFailed, .connectRejected, .connectInvalidApp:
            report(.serverRefused)
        default:
            break
        }
    }

    private func handleStreamStatus(_ status: RTMPStatus) {
        switch RTMPStream.Code(rawValue: status.code) {
        case .publishStart:
            continuation.yield(.publishing)
        case .publishBadName:
            report(.streamKeyRejected)
        case .connectRejected:
            report(.serverRefused)
        case .connectClosed, .connectFailed, .failed:
            report(.connectionLost)
        case .unpublishSuccess:
            // We asked for this, or the server acknowledged our close. Not a failure.
            break
        default:
            break
        }
    }

    /// Reports a drop, but only if there was a broadcast to drop. Everything after this point is
    /// the controller's decision — whether to reconnect, and what to put on screen.
    private func report(_ failure: BroadcastFailure) {
        guard isPublishing else { return }
        isPublishing = false
        continuation.yield(.disconnected(failure))
    }

    // MARK: - Translating the library's errors

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

    /// The server's own reason, when it gave one. A rejected stream key arrives here, and it is the
    /// difference between telling the user to check their key and telling them to check the
    /// network.
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
            options: [.defaultToSpeaker, .allowBluetooth]
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

extension HaishinKitStreamingSession: MTHKViewRepresentable.PreviewSource {
    /// Called by SwiftUI once, when the preview view is created. The view is attached to the
    /// *mixer*, so it renders the camera regardless of whether anything is being published — and
    /// if capture has not started yet, it is remembered until it has.
    nonisolated func connect(to view: MTHKView) {
        Task { await attach(previewView: view) }
    }
}
