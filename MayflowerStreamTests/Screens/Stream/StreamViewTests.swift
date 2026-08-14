//
//  StreamViewTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import SwiftUI
import Testing

@testable import MayflowerStream

@Suite("When the broadcast is torn down for a scene phase change")
struct StreamViewTests {

    @Test("Backgrounding shuts the broadcast down")
    func backgroundShutsDown() {
        #expect(StreamView.shouldShutDown(on: .background))
    }

    @Test("Inactive does not shut the broadcast down")
    func inactiveDoesNotShutDown() {
        #expect(!StreamView.shouldShutDown(on: .inactive))
    }

    @Test("Active does not shut the broadcast down")
    func activeDoesNotShutDown() {
        #expect(!StreamView.shouldShutDown(on: .active))
    }
}

@Suite("What the failure card offers")
struct StreamViewFailureCardTests {

    @Test("A rejected stream key offers the setup screen instead of a retry that cannot work")
    func aRejectedKeyIsSentBackToTheSetupScreen() {
        #expect(StreamView.cardActions(for: .streamKeyRejected) == [.editConfiguration])
    }

    @Test("Every other failure the user can act on still offers Try again")
    func otherFailuresKeepTryAgain() {
        #expect(StreamView.cardActions(for: .connectionLost) == [.tryAgain])
        #expect(StreamView.cardActions(for: .serverRefused) == [.tryAgain])
        #expect(StreamView.cardActions(for: .reconnectionGaveUp(attempts: 5)) == [.tryAgain])
        #expect(StreamView.cardActions(for: .cameraUnavailable) == [.tryAgain])
        #expect(StreamView.cardActions(for: .unexpected(detail: "-12345")) == [.tryAgain])
    }

    @Test("A permission failure keeps Open Settings ahead of Try again")
    func permissionFailuresLeadWithSettings() {
        #expect(StreamView.cardActions(for: .cameraAccessDenied) == [.openSettings, .tryAgain])
        #expect(StreamView.cardActions(for: .microphoneAccessDenied) == [.openSettings, .tryAgain])
    }

    /// Open Settings is offered on a refusal because the switch is there; on a restricted device it is not, so the card offers nothing rather than a dead end.
    @Test("Access blocked by a restriction offers no Settings button and no retry")
    func restrictedAccessOffersNothing() {
        #expect(StreamView.cardActions(for: .cameraAccessRestricted).isEmpty)
        #expect(StreamView.cardActions(for: .microphoneAccessRestricted).isEmpty)
    }

    @Test("Settings the app cannot run leave nothing to tap")
    func unsupportedConfigurationOffersNothing() {
        let unsupported = BroadcastFailure.unsupportedConfiguration(reason: "The frame rate is too high.")
        #expect(StreamView.cardActions(for: unsupported).isEmpty)
    }
}

@Suite("What the on-air HUD shows")
struct StreamStatisticsOnAirSummaryTests {

    @Test("Fast enough for megabits, the summary switches units")
    func megabitSpeedGetsOneDecimal() {
        let statistics = StreamStatistics(
            configured: .default,
            currentFrameRate: 24,
            currentBytesPerSecond: 262_500
        )
        #expect(statistics.onAirSummary == "24 fps · 2.1 Mbit/s")
    }

    @Test("Below the megabit threshold, the summary stays in kilobits and drops the fps part when it is missing")
    func kilobitSpeedWithoutFrameRate() {
        let statistics = StreamStatistics(
            configured: .default,
            currentBytesPerSecond: 100_000
        )
        #expect(statistics.onAirSummary == "800 kbit/s")
    }

    @Test("Nothing measured yet means nothing truthful to show")
    func nothingMeasuredIsNil() {
        let statistics = StreamStatistics(configured: .default)
        #expect(statistics.onAirSummary == nil)
    }

    @Test("Zero of both is a monitor that has not ticked yet, not a stalled broadcast")
    func zeroOfBothIsNothingMeasuredEither() {
        // The library's one-second network monitor starts both numbers at zero, so "0 fps · 0 kbit/s" would misread as a stalled stream on every broadcast's first second.
        let statistics = StreamStatistics(
            configured: .default,
            currentFrameRate: 0,
            currentBytesPerSecond: 0
        )
        #expect(statistics.onAirSummary == nil)
    }

    @Test("A frame rate with no data rate beside it is shown on its own")
    func frameRateWithoutASpeed() {
        let statistics = StreamStatistics(configured: .default, currentFrameRate: 30)
        #expect(statistics.onAirSummary == "30 fps")
    }

    @Test("VoiceOver is given the units in words, from the same numbers")
    func theSpokenLineSpellsTheUnitsOut() {
        let statistics = StreamStatistics(
            configured: .default,
            currentFrameRate: 30,
            currentBytesPerSecond: 328_000
        )
        #expect(
            statistics.onAirAccessibilityLabel == "Stream rate: 30 frames per second, 2.6 megabits per second"
        )
        #expect(StreamStatistics(configured: .default).onAirAccessibilityLabel == nil)
    }

    @Test("The unit switches at exactly one megabit per second")
    func theMegabitThresholdIsExact() {
        let below = StreamStatistics(configured: .default, currentBytesPerSecond: 124_999)
        let at = StreamStatistics(configured: .default, currentBytesPerSecond: 125_000)
        #expect(below.onAirSummary == "999 kbit/s")
        #expect(at.onAirSummary == "1.0 Mbit/s")
    }
}
