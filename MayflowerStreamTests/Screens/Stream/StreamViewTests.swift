//
//  StreamViewTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import SwiftUI
import Testing

@testable import MayflowerStream

@Suite("What a scene phase change does to the broadcast")
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

    @Test("Becoming active is what asks for the preview back")
    func activeRestoresThePreview() {
        #expect(StreamView.shouldRestorePreview(on: .active))
    }

    @Test("Inactive asks for nothing back")
    func inactiveRestoresNothing() {
        #expect(!StreamView.shouldRestorePreview(on: .inactive))
    }

    @Test("Backgrounding asks for nothing back")
    func backgroundRestoresNothing() {
        #expect(!StreamView.shouldRestorePreview(on: .background))
    }
}

@Suite("What the stream screen puts behind the controls")
struct StreamViewBackdropTests {

    /// The bug this answers: the restore releases the camera before it starts it again, so the *Turn on the camera* screen flashes over a camera the app is already bringing back.
    @Test("A restore never shows the camera-off screen, whatever the camera is doing at that instant")
    func aRestoreHidesTheCameraOffScreen() {
        #expect(StreamView.backdrop(isRestoring: true, isCapturing: false, state: .offline) == .restoringCamera)
        #expect(StreamView.backdrop(isRestoring: true, isCapturing: true, state: .offline) == .restoringCamera)
    }

    @Test("A restore that has reached the ladder names the broadcast instead of still blaming the camera")
    func aRestoreOnTheLadderNamesTheBroadcast() {
        #expect(
            StreamView.backdrop(isRestoring: true, isCapturing: true, state: .reconnecting(attempt: 2))
                == .resumingBroadcast
        )
    }

    @Test("Outside a restore the camera decides what is shown")
    func outsideARestoreTheCameraDecides() {
        #expect(StreamView.backdrop(isRestoring: false, isCapturing: true, state: .online) == .preview)
        #expect(StreamView.backdrop(isRestoring: false, isCapturing: false, state: .offline) == .cameraOff)
    }

    /// An ordinary drop mid-broadcast reconnects with the camera still running, and covering the live preview with a spinner would hide the shot the user is still framing.
    @Test("A reconnection with no restore behind it keeps the preview")
    func anOrdinaryReconnectionKeepsThePreview() {
        #expect(
            StreamView.backdrop(isRestoring: false, isCapturing: true, state: .reconnecting(attempt: 1)) == .preview
        )
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

/// The device trace counted three of everything: three controllers, three sessions with an event reader each. SwiftUI constructs the view struct on every invalidation and installs the first one it was given, so anything the struct's `init` builds is built once per construction and only one of them is ever used again — the rest keep running behind a screen that was thrown away.
@MainActor
@Suite("What constructing the stream screen costs")
struct StreamScreenTests {

    private static let endpoint = StreamEndpoint(connectURL: "rtmp://example.com/app", streamKey: "k")

    @Test("Constructing the screen opens neither a session nor a controller")
    func constructingTheScreenOpensNothing() {
        let screen = StreamScreen(endpoint: Self.endpoint)

        #expect(
            screen.hasOpened == false,
            "a session and a controller were opened for a screen SwiftUI may throw away unused, and both keep running once they exist"
        )
    }

    @Test("The screen opens once, however often it is asked")
    func theScreenOpensOnce() {
        let screen = StreamScreen(endpoint: Self.endpoint)

        let controller = screen.controller
        let session = screen.session

        #expect(screen.hasOpened)
        #expect(screen.controller === controller, "a second controller for one visit to the screen")
        #expect(screen.session === session, "a second session for one visit to the screen")
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
