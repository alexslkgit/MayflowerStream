//
//  BroadcastFailureTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import Foundation
import Testing

@testable import MayflowerStream

@Suite("Failure messages")
struct BroadcastFailureTests {

    private static let all: [BroadcastFailure] = [
        .cameraAccessDenied, .microphoneAccessDenied, .cameraAccessRestricted,
        .microphoneAccessRestricted, .cameraMissing(.front), .cameraMissing(.back),
        .cameraUnavailable, .microphoneUnavailable, .audioSessionUnavailable, .captureInterrupted,
        .unsupportedConfiguration(reason: "The frame rate is too high."), .encoderConfigurationFailed,
        .serverUnreachable, .connectionTimedOut, .streamKeyRejected, .serverRefused,
        .connectionLost, .reconnectionGaveUp(attempts: 5), .unexpected(detail: "-12345"),
    ]

    @Test("Every failure has a sentence for the user and none of them leak jargon")
    func everyFailureIsSayable() {
        let jargon = ["RTMP", "NetConnection", "OSStatus", "AVCapture", "nil", "Error(", "Optional"]
        for failure in Self.all {
            #expect(!failure.message.isEmpty, "\(failure) has no message")
            #expect(failure.message.hasSuffix("."), "\(failure) is not a sentence")
            for term in jargon {
                #expect(!failure.message.contains(term), "\(failure) leaks \(term) to the user")
            }
        }
    }

    @Test("Only failures that could succeed on a second try are retried automatically")
    func retriesOnlyWhatCanSucceed() {
        #expect(BroadcastFailure.connectionLost.isWorthRetrying)
        #expect(BroadcastFailure.connectionTimedOut.isWorthRetrying)
        #expect(BroadcastFailure.serverUnreachable.isWorthRetrying)

        #expect(BroadcastFailure.streamKeyRejected.isWorthRetrying == false)
        #expect(BroadcastFailure.serverRefused.isWorthRetrying == false)
        #expect(BroadcastFailure.cameraAccessDenied.isWorthRetrying == false)
        #expect(BroadcastFailure.unsupportedConfiguration(reason: "x").isWorthRetrying == false)
        #expect(
            BroadcastFailure.reconnectionGaveUp(attempts: 5).isWorthRetrying == false,
            "giving up must not start another round of giving up"
        )
    }

    /// Unlike `isWorthRetrying`, which decides what the app does on its own, this decides whether the user is offered a button at all.
    @Test("A failure the user cannot do anything about is offered no Try again")
    func offersTryAgainOnlyWhereItCouldHelp() {
        #expect(
            BroadcastFailure.unsupportedConfiguration(reason: "The frame rate is too high.")
                .isUserRetryable == false,
            "a button that runs the same impossible settings again and fails the same way"
        )

        for failure: BroadcastFailure in [
            .cameraAccessDenied, .cameraMissing(.front), .cameraUnavailable, .streamKeyRejected,
            .connectionLost, .reconnectionGaveUp(attempts: 3), .unexpected(detail: "-12345"),
        ] {
            #expect(failure.isUserRetryable, "\(failure) leaves the user with nothing to tap")
        }
    }

    /// A restriction is not a refusal: the user never made the choice and cannot unmake it, so the text must not send them to a switch that is not there.
    @Test("Access blocked by a restriction is not described as a refusal the user can lift")
    func aRestrictionIsNotDescribedAsARefusal() {
        for failure: BroadcastFailure in [.cameraAccessRestricted, .microphoneAccessRestricted] {
            #expect(failure.isUserRetryable == false, "\(failure) offers a retry that cannot work")
            #expect(failure.isWorthRetrying == false)
            #expect(failure.isDeviceProblem, "\(failure) is about this device, not about the stream")
            let recovery = failure.recovery ?? ""
            #expect(
                !recovery.contains("Settings"),
                "\(failure) points at a Settings switch that a restricted device does not show"
            )
            #expect(recovery.contains("Screen Time"), "\(failure) never says what is actually blocking it")
        }
        #expect(BroadcastFailure.cameraAccessRestricted.message != BroadcastFailure.cameraAccessDenied.message)
    }

    /// Unlike `isUserRetryable`, which says a button is worth offering, this says it cannot be "Try again" because the same configuration would be sent again.
    @Test("Only a rejected stream key sends the user back to the setup screen")
    func onlyARejectedKeyNeedsReconfiguration() {
        #expect(BroadcastFailure.streamKeyRejected.requiresReconfiguration)

        for failure in Self.all where failure != .streamKeyRejected {
            #expect(
                failure.requiresReconfiguration == false,
                "\(failure) sends the user to the setup screen with nothing there to change"
            )
        }
    }

    /// Adding a case to `BroadcastFailure` stops this file compiling until it is named here, and the count below fails until it is added to `all`, catching a case with no message or test.
    private static func name(of failure: BroadcastFailure) -> String {
        switch failure {
        case .cameraAccessDenied: "cameraAccessDenied"
        case .microphoneAccessDenied: "microphoneAccessDenied"
        case .cameraAccessRestricted: "cameraAccessRestricted"
        case .microphoneAccessRestricted: "microphoneAccessRestricted"
        case .cameraMissing: "cameraMissing"
        case .cameraUnavailable: "cameraUnavailable"
        case .microphoneUnavailable: "microphoneUnavailable"
        case .audioSessionUnavailable: "audioSessionUnavailable"
        case .captureInterrupted: "captureInterrupted"
        case .unsupportedConfiguration: "unsupportedConfiguration"
        case .encoderConfigurationFailed: "encoderConfigurationFailed"
        case .serverUnreachable: "serverUnreachable"
        case .connectionTimedOut: "connectionTimedOut"
        case .streamKeyRejected: "streamKeyRejected"
        case .serverRefused: "serverRefused"
        case .connectionLost: "connectionLost"
        case .reconnectionGaveUp: "reconnectionGaveUp"
        case .unexpected: "unexpected"
        }
    }

    @Test("Every case of the failure type is exercised by this suite")
    func everyCaseIsCovered() {
        let covered = Set(Self.all.map(Self.name(of:)))
        #expect(
            covered.count == 18,
            "a case was added to BroadcastFailure but not to the list this suite checks"
        )
    }

    @Test("Failures divide cleanly into device problems and broadcast problems")
    func deviceAndBroadcastProblemsAreSeparate() {
        for failure in Self.all where failure.isDeviceProblem {
            #expect(
                failure.isWorthRetrying == false,
                "\(failure) would be retried as if the connection had dropped"
            )
        }
        #expect(BroadcastFailure.cameraMissing(.front).isDeviceProblem)
        #expect(BroadcastFailure.microphoneUnavailable.isDeviceProblem)
        #expect(BroadcastFailure.audioSessionUnavailable.isDeviceProblem)
        #expect(BroadcastFailure.encoderConfigurationFailed.isDeviceProblem)
        #expect(BroadcastFailure.streamKeyRejected.isDeviceProblem == false)
        #expect(BroadcastFailure.connectionLost.isDeviceProblem == false)
        #expect(BroadcastFailure.reconnectionGaveUp(attempts: 3).isDeviceProblem == false)
    }

    @Test("The unexpected case keeps its detail for a log but never shows it")
    func unexpectedKeepsDetailOutOfSight() {
        let failure = BroadcastFailure.unexpected(detail: "NetConnection.Connect.Whatever")
        #expect(!failure.message.contains("NetConnection"))
        #expect(failure.diagnosticDescription.contains("NetConnection"))
    }
}
