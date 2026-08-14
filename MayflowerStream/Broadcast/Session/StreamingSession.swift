//
//  StreamingSession.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation

protocol StreamingSession: Sendable {

    /// Stored, not computed — HaishinKit's own status streams re-arm on every read of the
    /// property, silently disconnecting the previous reader. Iterate exactly once.
    var events: AsyncStream<StreamingEvent> { get }

    func startCapture(_ configuration: BroadcastConfiguration) async throws(BroadcastFailure)

    /// Assumes publishing has already been stopped — teardown takes the mixer down without
    /// notifying the server — which is why `BroadcastController.shutDown()` stops publishing first.
    func stopCapture() async

    func switchCamera(to facing: CameraFacing) async throws(BroadcastFailure)

    /// Returns what is actually in force, read back rather than assumed.
    func setMicrophoneMuted(_ isMuted: Bool) async -> Bool

    /// A call that throws must leave nothing open behind it: the retry button and automatic
    /// reconnection both depend on the next call being able to succeed.
    func startPublishing(to endpoint: StreamEndpoint) async throws(BroadcastFailure)

    /// Leaves capture running.
    func stopPublishing() async

    /// Safe to call before capture has started; applied when the pipeline is built.
    func setOverlay(_ overlay: (any StreamOverlay)?) async

    func currentStatistics() async -> StreamStatistics
}

/// Things that happen to the session without the app asking.
enum StreamingEvent: Equatable, Sendable {
    case publishing
    case disconnected(BroadcastFailure)
    /// Camera/mic taken away (phone call, another app). The connection knows nothing about this,
    /// so without this event the screen would keep saying Online over a frozen picture.
    case captureInterrupted
    case captureResumed
}

/// `configured` is what the app asked for; the `applied*` fields are read back from the encoder
/// rather than assumed, so they can be compared to catch a silent mismatch.
struct StreamStatistics: Equatable, Sendable {
    var configured: BroadcastConfiguration

    var appliedVideoSize: CGSize?
    var appliedVideoBitRate: Int?
    var appliedVideoCodec: String?
    var appliedAudioBitRate: Int?
    var appliedAudioCodec: String?
    var currentFrameRate: Int?
    var currentBytesPerSecond: Int?

    init(
        configured: BroadcastConfiguration,
        appliedVideoSize: CGSize? = nil,
        appliedVideoBitRate: Int? = nil,
        appliedVideoCodec: String? = nil,
        appliedAudioBitRate: Int? = nil,
        appliedAudioCodec: String? = nil,
        currentFrameRate: Int? = nil,
        currentBytesPerSecond: Int? = nil
    ) {
        self.configured = configured
        self.appliedVideoSize = appliedVideoSize
        self.appliedVideoBitRate = appliedVideoBitRate
        self.appliedVideoCodec = appliedVideoCodec
        self.appliedAudioBitRate = appliedAudioBitRate
        self.appliedAudioCodec = appliedAudioCodec
        self.currentFrameRate = currentFrameRate
        self.currentBytesPerSecond = currentBytesPerSecond
    }

    /// `currentFrameRate` and `currentBytesPerSecond` are excluded deliberately: both vary
    /// normally on a healthy broadcast and have no fixed setting to compare against.
    var matchesConfiguration: Bool {
        if let appliedVideoSize, appliedVideoSize != configured.videoSize { return false }
        if let appliedVideoBitRate, appliedVideoBitRate != configured.videoBitRate { return false }
        if let appliedAudioBitRate, appliedAudioBitRate != configured.audioBitRate { return false }
        if let appliedVideoCodec, appliedVideoCodec != BroadcastConfiguration.videoCodec { return false }
        if let appliedAudioCodec, appliedAudioCodec != BroadcastConfiguration.audioCodec { return false }
        return true
    }
}
