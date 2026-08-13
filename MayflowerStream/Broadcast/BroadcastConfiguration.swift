//
//  BroadcastConfiguration.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import CoreGraphics
import Foundation

/// The settings the broadcast is asked to run with.
///
/// Codecs are not settings. The task fixes them at H.264 and AAC, so they are constants here and
/// are reported to the user rather than chosen by them.
struct BroadcastConfiguration: Equatable, Sendable {
    var videoSize: CGSize
    /// Bits per second.
    var videoBitRate: Int
    /// Bits per second.
    var audioBitRate: Int
    var frameRate: Double
    var keyFrameIntervalSeconds: Double
    var cameraFacing: CameraFacing

    static let videoCodec = "H.264"
    static let audioCodec = "AAC"

    /// Portrait 720p at 2.5 Mbps. Comfortably inside every limit checked below, and a resolution
    /// every iPhone since the 6s can produce from either camera.
    static let `default` = BroadcastConfiguration(
        videoSize: CGSize(width: 720, height: 1280),
        videoBitRate: 2_500_000,
        audioBitRate: 128_000,
        frameRate: 30,
        keyFrameIntervalSeconds: 2,
        cameraFacing: .back
    )
}

extension BroadcastConfiguration {
    /// Limits taken from Twitch's published broadcasting requirements, checked 2026-08-11.
    /// They are the tightest of the services this app is likely to be pointed at, so validating
    /// against them keeps the app from starting a broadcast the server will drop.
    enum Limits {
        static let videoBitRate = 500_000...6_000_000
        static let audioBitRate = 64_000...160_000
        static let frameRate = 1.0...60.0
        static let keyFrameIntervalSeconds = 1.0...4.0
        static let shortestSide = 240.0
        static let longestSide = 1920.0
    }

    /// Checked before anything is opened, so an impossible configuration is refused with a reason
    /// instead of failing somewhere inside the encoder.
    ///
    /// This covers what can be known without hardware. Whether *this particular device* can
    /// actually produce the requested size from the requested camera is a different question, and
    /// is answered by the capture session when it starts.
    func validate() throws(BroadcastFailure) {
        let width = videoSize.width
        let height = videoSize.height

        guard width > 0, height > 0 else {
            throw .unsupportedConfiguration(reason: "The video size must be larger than zero.")
        }
        guard width.truncatingRemainder(dividingBy: 2) == 0,
              height.truncatingRemainder(dividingBy: 2) == 0 else {
            // H.264 encodes colour at half resolution, so an odd number of pixels has nowhere to go.
            throw .unsupportedConfiguration(
                reason: "The video width and height must both be even numbers."
            )
        }
        guard min(width, height) >= Limits.shortestSide else {
            throw .unsupportedConfiguration(
                reason: "The video is too small to broadcast. The shorter side must be at least \(Int(Limits.shortestSide)) pixels."
            )
        }
        guard max(width, height) <= Limits.longestSide else {
            throw .unsupportedConfiguration(
                reason: "The video is too large to broadcast. The longer side can be at most \(Int(Limits.longestSide)) pixels."
            )
        }
        guard Limits.videoBitRate.contains(videoBitRate) else {
            throw .unsupportedConfiguration(
                reason: "The video quality is outside what the server accepts. Pick a video bitrate between \(Limits.videoBitRate.lowerBound / 1000) and \(Limits.videoBitRate.upperBound / 1000) kbps."
            )
        }
        guard Limits.audioBitRate.contains(audioBitRate) else {
            throw .unsupportedConfiguration(
                reason: "The audio quality is outside what the server accepts. Pick an audio bitrate between \(Limits.audioBitRate.lowerBound / 1000) and \(Limits.audioBitRate.upperBound / 1000) kbps."
            )
        }
        guard Limits.frameRate.contains(frameRate) else {
            throw .unsupportedConfiguration(
                reason: "The frame rate must be between \(Int(Limits.frameRate.lowerBound)) and \(Int(Limits.frameRate.upperBound)) frames per second."
            )
        }
        guard Limits.keyFrameIntervalSeconds.contains(keyFrameIntervalSeconds) else {
            throw .unsupportedConfiguration(
                reason: "The keyframe interval must be between \(Int(Limits.keyFrameIntervalSeconds.lowerBound)) and \(Int(Limits.keyFrameIntervalSeconds.upperBound)) seconds."
            )
        }
    }
}
