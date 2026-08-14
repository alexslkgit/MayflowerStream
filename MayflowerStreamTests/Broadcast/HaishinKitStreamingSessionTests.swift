//
//  HaishinKitStreamingSessionTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import Foundation
import Testing

@testable import MayflowerStream

/// The one decision in the session that cannot be reached from `FakeStreamingSession`, pulled out as a function so it can be checked here without a camera or a server.
@Suite("What a publish that was never confirmed is called")
struct PublishHandshakeFailureTests {

    /// Stands in for whatever the library throws when its publish request goes unanswered; what it is does not matter to the decision under test.
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

/// Only the half of the epoch discipline reachable without a camera is pinned here — that a stop with nothing to stop still moves it; the other half needs a real capture device and is verified there.
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

        // A flag would answer the first stop and be indistinguishable from the second; a start between the two has to tell them apart.
        #expect(await session.captureGeneration == before + 2)
    }
}

/// The event stream is read by a task that is never cancelled (see `BroadcastController.shutDown()`), so finishing it is the session's job and nobody else's.
@MainActor
@Suite("What becomes of the event stream when the session goes away")
struct EventStreamLifetimeTests {

    /// Written by the reader task and read by the test, so it cannot be a local variable.
    @MainActor
    private final class ReaderCompletion {
        var didFinish = false
    }

    @Test("A session that is released finishes its event stream, so its reader is not left suspended")
    func aReleasedSessionFinishesItsEventStream() async throws {
        let completion = ReaderCompletion()
        let events: AsyncStream<StreamingEvent>
        // Only the stream is kept, matching what the controller holds: nothing points at the session once its screen is gone.
        do {
            let session = HaishinKitStreamingSession()
            events = session.events
        }

        Task {
            for await _ in events {}
            completion.didFinish = true
        }

        try await waitUntil("the reader of a released session's stream to finish") {
            completion.didFinish
        }
    }
}
