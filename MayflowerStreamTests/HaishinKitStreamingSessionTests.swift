//
//  HaishinKitStreamingSessionTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import Foundation
import Testing

@testable import MayflowerStream

/// The one decision in the session that cannot be reached from `FakeStreamingSession`, pulled out
/// as a function precisely so it can be checked here without a camera or a server.
@Suite("What a publish that was never confirmed is called")
struct PublishHandshakeFailureTests {

    /// Stands in for whatever the library throws when its publish request goes unanswered. What it
    /// is does not matter to the decision under test.
    private struct LibraryError: Error {}

    @Test("A connection closed inside the publish handshake is a refused stream key")
    func aCloseDuringTheHandshakeIsARejectedKey() {
        let failure = HaishinKitStreamingSession.publishFailure(
            from: LibraryError(),
            closedDuringHandshake: true
        )

        #expect(
            failure == .streamKeyRejected,
            "a bad key was reported as \(failure), which sends the user to their router"
        )
        #expect(failure.isWorthRetrying == false, "a key that was refused will be refused again")
    }

    @Test("A publish that failed for a reason of its own keeps that reason")
    func otherPublishFailuresKeepTheirOwnReason() {
        let failure = HaishinKitStreamingSession.publishFailure(
            from: LibraryError(),
            closedDuringHandshake: false
        )

        #expect(failure != .streamKeyRejected, "every failed publish now blames the stream key")
        #expect(failure == .unexpected(detail: String(describing: LibraryError())))
    }
}

/// Backgrounding the app while the camera is still opening. `startCapture` is awaiting its device
/// attaches, so it holds a pipeline nothing else can see yet, and the `stopCapture` that arrives
/// there finds nothing to stop — it is the epoch it leaves behind that tells the start in flight
/// its result is no longer wanted.
///
/// Only the half of that discipline which needs no camera is pinned here: that the epoch moves for
/// a stop with nothing to stop. The other half — the start reading it back after its awaits and
/// tearing down what it has just built — cannot be reached on a machine with no capture device,
/// because `startCapture` throws `.cameraMissing` before it ever reaches an await. It is verified
/// on a device, like the rest of `HaishinKitStreamingSession`.
@Suite("Stopping a capture that has not finished starting")
struct CaptureGenerationTests {

    @Test("A stop with nothing to stop still moves the epoch")
    func aStopWithNothingToStopStillMovesTheEpoch() async {
        let session = HaishinKitStreamingSession()
        let before = await session.captureGeneration

        // No pipeline has been built, which is exactly what a stop arriving mid-start sees.
        await session.stopCapture()

        #expect(
            await session.captureGeneration == before + 1,
            "a stop that found nothing to stop left no trace, so a start in flight cannot see it"
        )
    }

    @Test("Each stop moves it again, so no two starts read the same epoch")
    func eachStopMovesItAgain() async {
        let session = HaishinKitStreamingSession()
        let before = await session.captureGeneration

        await session.stopCapture()
        await session.stopCapture()

        // A flag would answer the first stop and then be indistinguishable from the second. A start
        // that began between the two has to be able to tell them apart.
        #expect(await session.captureGeneration == before + 2)
    }
}
