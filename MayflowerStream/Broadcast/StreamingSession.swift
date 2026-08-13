//
//  StreamingSession.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation

/// Everything the app needs from a streaming library, and nothing else.
///
/// The one seam in the app. It keeps HaishinKit's actor-isolated API out of the view layer; it
/// lets the state machine and every error path be tested without a camera, a microphone or a
/// server; and it is where a frame-processing step — a clock burned into the outgoing picture,
/// say — would be added, because that is the only place frames pass through on their way from the
/// capture session to the encoder.
///
/// Capture and publishing are deliberately separate. The user gets a preview before going live,
/// and stopping a broadcast leaves the camera running so it can be started again immediately.
protocol StreamingSession: Sendable {

    /// Established once, when the session is created. **Iterate exactly once.**
    /// HaishinKit's own status streams re-arm their continuation on every read of the property,
    /// which silently disconnects the previous reader — so this is a stored stream, not a computed
    /// one, and the controller owns the single task that drains it.
    var events: AsyncStream<StreamingEvent> { get }

    /// Nothing before this call touches AVFoundation.
    func startCapture(_ configuration: BroadcastConfiguration) async throws(BroadcastFailure)

    /// Safe to call when capture was never started.
    func stopCapture() async

    func switchCamera(to facing: CameraFacing) async throws(BroadcastFailure)

    /// Applies the setting and returns what is actually in force, so the caller never has to
    /// assume its own request took effect.
    func setMicrophoneMuted(_ isMuted: Bool) async -> Bool

    /// Throws if the server rejects the attempt outright; a connection that succeeds and then
    /// drops arrives as a `.disconnected` event instead.
    ///
    /// A call that throws must leave nothing open behind it: the next call has to be able to
    /// succeed, because that next call is how both the retry button and automatic reconnection
    /// work.
    func startPublishing(to endpoint: StreamEndpoint) async throws(BroadcastFailure)

    /// Leaves capture running.
    func stopPublishing() async

    /// Safe to call before capture has started; it is applied when the pipeline is built.
    func setOverlay(_ overlay: (any StreamOverlay)?) async

    func currentStatistics() async -> StreamStatistics
}

/// Things that happen to the session without the app asking.
enum StreamingEvent: Equatable, Sendable {
    /// The server accepted the stream and frames are going out.
    case publishing
    /// The connection ended on its own. The reason is already translated for the user.
    case disconnected(BroadcastFailure)
}

/// A snapshot of the outgoing stream, shown in the parameters sheet.
///
/// `configured` is what the app asked for. `applied` is what the encoder says it took, read back
/// out of the SDK rather than assumed. They are separate fields on purpose: if they ever disagree,
/// the user sees it instead of being told everything is fine.
///
/// `currentFrameRate` is the only measured number here. Everything else is a setting.
struct StreamStatistics: Equatable, Sendable {
    var configured: BroadcastConfiguration

    var appliedVideoSize: CGSize?
    var appliedVideoBitRate: Int?
    var appliedVideoCodec: String?
    var appliedAudioBitRate: Int?
    var appliedAudioCodec: String?
    var currentFrameRate: Int?

    init(
        configured: BroadcastConfiguration,
        appliedVideoSize: CGSize? = nil,
        appliedVideoBitRate: Int? = nil,
        appliedVideoCodec: String? = nil,
        appliedAudioBitRate: Int? = nil,
        appliedAudioCodec: String? = nil,
        currentFrameRate: Int? = nil
    ) {
        self.configured = configured
        self.appliedVideoSize = appliedVideoSize
        self.appliedVideoBitRate = appliedVideoBitRate
        self.appliedVideoCodec = appliedVideoCodec
        self.appliedAudioBitRate = appliedAudioBitRate
        self.appliedAudioCodec = appliedAudioCodec
        self.currentFrameRate = currentFrameRate
    }

    /// `currentFrameRate` is deliberately not part of this. It is measured rather than reported,
    /// and a camera delivering 29 of the 30 frames it was asked for is not a misconfigured
    /// encoder — counting it here would put a warning on every healthy broadcast.
    var matchesConfiguration: Bool {
        if let appliedVideoSize, appliedVideoSize != configured.videoSize { return false }
        if let appliedVideoBitRate, appliedVideoBitRate != configured.videoBitRate { return false }
        if let appliedAudioBitRate, appliedAudioBitRate != configured.audioBitRate { return false }
        if let appliedVideoCodec, appliedVideoCodec != BroadcastConfiguration.videoCodec { return false }
        if let appliedAudioCodec, appliedAudioCodec != BroadcastConfiguration.audioCodec { return false }
        return true
    }
}
