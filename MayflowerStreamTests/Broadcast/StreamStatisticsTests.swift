//
//  StreamStatisticsTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import Foundation
import Testing

@testable import MayflowerStream

@Suite("What the parameters sheet is told")
struct StreamStatisticsTests {

    private static func statistics(
        videoSize: CGSize? = nil,
        videoBitRate: Int? = nil,
        videoCodec: String? = nil,
        audioBitRate: Int? = nil,
        audioCodec: String? = nil,
        frameRate: Int? = nil
    ) -> StreamStatistics {
        StreamStatistics(
            configured: .default,
            appliedVideoSize: videoSize,
            appliedVideoBitRate: videoBitRate,
            appliedVideoCodec: videoCodec,
            appliedAudioBitRate: audioBitRate,
            appliedAudioCodec: audioCodec,
            currentFrameRate: frameRate
        )
    }

    @Test("An encoder that reported nothing yet is not called a mismatch")
    func nothingReportedIsNotAMismatch() {
        #expect(Self.statistics().matchesConfiguration)
    }

    @Test("An encoder running exactly what it was asked for matches")
    func everythingAsAskedMatches() {
        let statistics = Self.statistics(
            videoSize: BroadcastConfiguration.default.videoSize,
            videoBitRate: BroadcastConfiguration.default.videoBitRate,
            videoCodec: BroadcastConfiguration.videoCodec,
            audioBitRate: BroadcastConfiguration.default.audioBitRate,
            audioCodec: BroadcastConfiguration.audioCodec,
            frameRate: 30
        )
        #expect(statistics.matchesConfiguration)
    }

    @Test("Every setting the encoder reports back is compared, one by one")
    func eachReportedSettingIsChecked() {
        #expect(Self.statistics(videoSize: CGSize(width: 640, height: 480)).matchesConfiguration == false)
        #expect(Self.statistics(videoBitRate: 1_000_000).matchesConfiguration == false)
        #expect(Self.statistics(videoCodec: "HEVC").matchesConfiguration == false)
        #expect(Self.statistics(audioBitRate: 64_000).matchesConfiguration == false)
        #expect(Self.statistics(audioCodec: "Opus").matchesConfiguration == false)
    }

    @Test("A measured frame rate below the configured one is not a mismatch")
    func aSlowCameraIsNotAMisconfiguredEncoder() {
        // 29 delivered frames out of 30 asked for is an ordinary healthy broadcast; flagging it would warn on the sheet every time.
        #expect(Self.statistics(frameRate: 29).matchesConfiguration)
        #expect(Self.statistics(frameRate: 0).matchesConfiguration)
    }
}
