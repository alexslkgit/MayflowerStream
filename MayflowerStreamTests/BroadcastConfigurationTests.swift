//
//  BroadcastConfigurationTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import Foundation
import Testing

@testable import MayflowerStream

@Suite("Broadcast configuration validation")
struct BroadcastConfigurationTests {

    @Test("The default configuration is valid")
    func defaultIsValid() throws {
        try BroadcastConfiguration.default.validate()
    }

    @Test("An odd video size is refused, because H.264 cannot encode it")
    func refusesOddDimensions() {
        var configuration = BroadcastConfiguration.default
        configuration.videoSize = CGSize(width: 721, height: 1280)
        #expect(throws: BroadcastFailure.self) { try configuration.validate() }
    }

    @Test("A video larger than the service accepts is refused")
    func refusesOversizedVideo() {
        var configuration = BroadcastConfiguration.default
        configuration.videoSize = CGSize(width: 2160, height: 3840)
        #expect(throws: BroadcastFailure.self) { try configuration.validate() }
    }

    @Test("Bitrates outside the service limits are refused")
    func refusesImpossibleBitrates() {
        var tooHigh = BroadcastConfiguration.default
        tooHigh.videoBitRate = 50_000_000
        #expect(throws: BroadcastFailure.self) { try tooHigh.validate() }

        var tooLow = BroadcastConfiguration.default
        tooLow.audioBitRate = 8_000
        #expect(throws: BroadcastFailure.self) { try tooLow.validate() }
    }

    @Test("Every refusal explains itself without jargon")
    func refusalsAreReadable() {
        var configuration = BroadcastConfiguration.default
        configuration.frameRate = 240

        do {
            try configuration.validate()
            Issue.record("240 fps should not have validated")
        } catch {
            let message = error.message
            #expect(!message.isEmpty)
            for term in ["nil", "throw", "enum", "Int", "CGSize"] {
                #expect(!message.contains(term), "the message leaks \(term)")
            }
        }
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
