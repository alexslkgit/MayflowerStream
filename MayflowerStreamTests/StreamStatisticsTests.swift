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
        // 29 delivered frames out of 30 asked for is an ordinary healthy broadcast. Counting it
        // here would put a warning on the sheet for every user, every time.
        #expect(Self.statistics(frameRate: 29).matchesConfiguration)
        #expect(Self.statistics(frameRate: 0).matchesConfiguration)
    }
}

@Suite("Configuration limits")
struct BroadcastConfigurationLimitTests {

    private static func configuration(
        _ change: (inout BroadcastConfiguration) -> Void
    ) -> BroadcastConfiguration {
        var configuration = BroadcastConfiguration.default
        change(&configuration)
        return configuration
    }

    @Test("A value sitting exactly on a limit is accepted")
    func boundariesAreInclusive() throws {
        try Self.configuration { $0.videoBitRate = BroadcastConfiguration.Limits.videoBitRate.lowerBound }.validate()
        try Self.configuration { $0.videoBitRate = BroadcastConfiguration.Limits.videoBitRate.upperBound }.validate()
        try Self.configuration { $0.audioBitRate = BroadcastConfiguration.Limits.audioBitRate.lowerBound }.validate()
        try Self.configuration { $0.audioBitRate = BroadcastConfiguration.Limits.audioBitRate.upperBound }.validate()
        try Self.configuration { $0.frameRate = BroadcastConfiguration.Limits.frameRate.upperBound }.validate()
        try Self.configuration { $0.keyFrameIntervalSeconds = BroadcastConfiguration.Limits.keyFrameIntervalSeconds.lowerBound }.validate()
        try Self.configuration { $0.keyFrameIntervalSeconds = BroadcastConfiguration.Limits.keyFrameIntervalSeconds.upperBound }.validate()
        try Self.configuration { $0.videoSize = CGSize(width: 240, height: 426) }.validate()
        try Self.configuration { $0.videoSize = CGSize(width: 1080, height: 1920) }.validate()
    }

    @Test("One step outside a limit is refused")
    func oneStepOutsideIsRefused() {
        let outside: [BroadcastConfiguration] = [
            Self.configuration { $0.videoBitRate = BroadcastConfiguration.Limits.videoBitRate.lowerBound - 1 },
            Self.configuration { $0.videoBitRate = BroadcastConfiguration.Limits.videoBitRate.upperBound + 1 },
            Self.configuration { $0.audioBitRate = BroadcastConfiguration.Limits.audioBitRate.lowerBound - 1 },
            Self.configuration { $0.audioBitRate = BroadcastConfiguration.Limits.audioBitRate.upperBound + 1 },
            Self.configuration { $0.frameRate = BroadcastConfiguration.Limits.frameRate.upperBound + 1 },
            Self.configuration { $0.frameRate = 0 },
            Self.configuration { $0.keyFrameIntervalSeconds = BroadcastConfiguration.Limits.keyFrameIntervalSeconds.lowerBound - 1 },
            Self.configuration { $0.keyFrameIntervalSeconds = BroadcastConfiguration.Limits.keyFrameIntervalSeconds.upperBound + 1 },
            Self.configuration { $0.videoSize = CGSize(width: 238, height: 426) },
            Self.configuration { $0.videoSize = CGSize(width: 1080, height: 1922) },
            Self.configuration { $0.videoSize = CGSize(width: 0, height: 0) },
            Self.configuration { $0.videoSize = CGSize(width: 721, height: 1280) },
        ]

        for configuration in outside {
            #expect(throws: BroadcastFailure.self) { try configuration.validate() }
        }
    }
}
