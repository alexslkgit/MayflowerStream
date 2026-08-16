//
//  BroadcastControllerTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation
import Testing

@testable import MayflowerStream

@MainActor
@Suite("Broadcast state machine")
struct BroadcastControllerTests {

    private static let endpoint = StreamEndpoint(connectURL: "rtmp://example.com/app", streamKey: "k")

    /// Reconnection with the waiting taken out, so the whole sequence runs in a test.
    private static let instantReconnect = ReconnectPolicy(maximumAttempts: 3) { _ in .zero }

    /// Long enough that a wait which is not skipped outlasts any `waitUntil` in this file.
    private static let patientReconnect = ReconnectPolicy(maximumAttempts: 3) { _ in .seconds(5) }

    /// Waits only after the first attempt, so a test can put the restore inside an *attempt* rather than the first backoff.
    private static let patientAfterTheFirstAttempt = ReconnectPolicy(maximumAttempts: 3) { attempt in
        attempt == 1 ? .zero : .seconds(5)
    }

    /// One attempt behind a wait short enough to run out of attempts inside a test.
    private static let oneAttemptAfterASecond = ReconnectPolicy(maximumAttempts: 1) { _ in .seconds(1) }

    /// A first wait short enough to sit through, so a test can watch a countdown end in an attempt.
    private static let aSecondThenPatient = ReconnectPolicy(maximumAttempts: 3) { attempt in
        attempt == 1 ? .seconds(1) : .seconds(5)
    }

    /// The countdown counts seconds of backoff, so a compressed tick shows the whole ladder at once.
    private static let instantCountdownTick = Duration.milliseconds(40)

    private func makeController(
        session: FakeStreamingSession,
        permissions: StubMediaPermissions = StubMediaPermissions(),
        configuration: BroadcastConfiguration = .default,
        reconnect: ReconnectPolicy = instantReconnect,
        connectivity: FakeConnectivityMonitor = FakeConnectivityMonitor(),
        countdownTick: Duration = instantCountdownTick,
        // Like the delays above: a test that is not about the settle after a restore does not sit through it.
        pathSettleDelay: Duration = .zero,
        heldSessionRecheck: Duration = .milliseconds(50)
    ) -> BroadcastController {
        BroadcastController(
            endpoint: Self.endpoint,
            session: session,
            permissions: permissions,
            configuration: configuration,
            reconnectPolicy: reconnect,
            connectivity: connectivity,
            countdownTick: countdownTick,
            pathSettleDelay: pathSettleDelay,
            heldSessionRecheck: heldSessionRecheck
        )
    }

    // MARK: - Nothing happens on its own

    @Test("Creating the controller opens nothing")
    func createsNothingUntilAsked() {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)

        #expect(controller.state == .offline)
        #expect(controller.isCapturing == false)
        #expect(session.captureStartCount == 0)
        #expect(session.publishStartCount == 0)
    }

    @Test("Start does nothing while the camera is not running")
    func refusesToPublishWithoutCapture() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)

        await controller.startBroadcast()

        #expect(session.publishStartCount == 0)
        #expect(controller.state == .offline)
    }

    // MARK: - Permissions

    @Test("Permission is asked for only when capture is started")
    func asksForPermissionJustInTime() async {
        let session = FakeStreamingSession()
        let permissions = StubMediaPermissions()
        let controller = makeController(session: session, permissions: permissions)

        #expect(permissions.requested.isEmpty)

        await controller.startCapture()

        #expect(permissions.requested == [.camera, .microphone])
        #expect(controller.isCapturing)
    }

    @Test("A refused camera stops there and says so")
    func refusedCameraIsReported() async {
        let session = FakeStreamingSession()
        let permissions = StubMediaPermissions(camera: .denied)
        let controller = makeController(session: session, permissions: permissions)

        await controller.startCapture()

        #expect(controller.state == .failed(.cameraAccessDenied))
        #expect(controller.isCapturing == false)
        #expect(session.captureStartCount == 0, "the camera must not be opened after a refusal")
        #expect(permissions.requested == [.camera], "no point asking for the microphone")
    }

    @Test("A refused microphone stops there and says so")
    func refusedMicrophoneIsReported() async {
        let session = FakeStreamingSession()
        let controller = makeController(
            session: session,
            permissions: StubMediaPermissions(microphone: .denied)
        )

        await controller.startCapture()

        #expect(controller.state == .failed(.microphoneAccessDenied))
        #expect(session.captureStartCount == 0)
    }

    @Test("A camera blocked by a restriction is not reported as a refusal the user made")
    func restrictedCameraIsReportedAsARestriction() async {
        let session = FakeStreamingSession()
        let permissions = StubMediaPermissions(camera: .restricted)
        let controller = makeController(session: session, permissions: permissions)

        await controller.startCapture()

        #expect(
            controller.state == .failed(.cameraAccessRestricted),
            "the user is sent to a Settings switch that a restricted device does not show"
        )
        #expect(session.captureStartCount == 0)
    }

    @Test("A microphone blocked by a restriction is reported the same way")
    func restrictedMicrophoneIsReportedAsARestriction() async {
        let session = FakeStreamingSession()
        let controller = makeController(
            session: session,
            permissions: StubMediaPermissions(microphone: .restricted)
        )

        await controller.startCapture()

        #expect(controller.state == .failed(.microphoneAccessRestricted))
        #expect(session.captureStartCount == 0)
    }

    // MARK: - Going live

    @Test("Going live waits for the server, not for the tap")
    func onlineOnlyWhenTheServerConfirms() async throws {
        let session = FakeStreamingSession()
        // The server takes its time answering, so until it does the user is told Connecting only.
        session.publishDelay = .milliseconds(80)
        let controller = makeController(session: session)
        await controller.startCapture()

        let starting = Task { await controller.startBroadcast() }
        try await waitUntil("connecting") { controller.state == .connecting }
        #expect(controller.state == .connecting, "publishing was requested but not yet confirmed")

        await starting.value
        try await waitUntil("state becomes online") { controller.state == .online }

        #expect(controller.state.isLive)
        #expect(controller.statistics != nil)
    }

    @Test("A confirmation that beats the call home does not tear the broadcast down")
    func earlyPublishingEventIsStillSuccess() async throws {
        let session = FakeStreamingSession()
        session.publishDelay = .milliseconds(80)
        let controller = makeController(session: session)
        await controller.startCapture()

        let starting = Task { await controller.startBroadcast() }
        try await waitUntil("connecting") { controller.state == .connecting }

        // `.publishing` lands while `startPublishing` is still in flight, so state is already `.online` by the time the call returns; that must read as success.
        session.emit(.publishing)
        try await waitUntil("online from the event") { controller.state == .online }

        await starting.value

        #expect(controller.state == .online)
        #expect(session.publishStopCount == 0, "the broadcast that just started must not be taken down")
    }

    @Test("A server that refuses the key ends in an error naming the key")
    func rejectedKeyIsReported() async {
        let session = FakeStreamingSession()
        session.publishFailures = [.streamKeyRejected]
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.startBroadcast()

        #expect(controller.state == .failed(.streamKeyRejected))
        #expect(controller.state.isLive == false)
    }

    @Test("An impossible configuration is refused before anything is opened")
    func invalidConfigurationNeverReachesTheServer() async {
        let session = FakeStreamingSession()
        var configuration = BroadcastConfiguration.default
        configuration.videoBitRate = 50_000_000
        let controller = makeController(session: session, configuration: configuration)
        await controller.startCapture()

        await controller.startBroadcast()

        #expect(session.publishStartCount == 0)
        #expect(controller.state.failure != nil)
        if case .unsupportedConfiguration = controller.state.failure {} else {
            Issue.record("expected an unsupported-configuration failure, got \(String(describing: controller.state.failure))")
        }
    }

    @Test("Stopping and starting again works")
    func stopsAndStartsAgain() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("first broadcast is online") { controller.state == .online }

        await controller.stopBroadcast()
        #expect(controller.state == .offline)
        #expect(controller.elapsedSeconds == 0)
        #expect(session.publishStopCount == 1)
        #expect(session.captureStopCount == 0, "the camera stays on so the user can go live again")

        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("second broadcast is online") { controller.state == .online }

        #expect(session.publishStartCount == 2)
    }

    @Test("Stop takes the panel offline while the goodbye is still on the wire")
    func stopIsInstantEvenWhenTheServerIsSlowToSayGoodbye() async throws {
        let session = FakeStreamingSession()
        // Closing the stream then the connection is two round-trips; the second is what the user waits on.
        session.stopPublishingDelay = .milliseconds(300)
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        let stopping = Task { await controller.stopBroadcast() }
        // The counter goes up as the goodbye starts, so everything below is asserted while it is still in flight.
        try await waitUntil("the goodbye is on the wire") { session.publishStopCount == 1 }

        #expect(controller.state == .offline, "the panel still said \(controller.state)")
        #expect(controller.elapsedSeconds == 0, "the duration kept running")
        #expect(controller.statistics == nil)

        await stopping.value
        #expect(controller.state == .offline)
        #expect(session.publishStopCount == 1, "the goodbye must be said once")
    }

    @Test("Start right after Stop waits the goodbye out instead of publishing over it")
    func startAfterStopDoesNotOverlapTheGoodbye() async throws {
        let session = FakeStreamingSession()
        session.stopPublishingDelay = .milliseconds(300)
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("first broadcast is online") { controller.state == .online }

        let stopping = Task { await controller.stopBroadcast() }
        try await waitUntil("the goodbye is on the wire") { session.publishStopCount == 1 }

        // The screen says Offline, so this is a tap the user can really make.
        let starting = Task { await controller.startBroadcast() }
        try await waitUntil("connecting") { controller.state == .connecting }
        #expect(
            session.publishStartCount == 1,
            "a second handshake was opened on a connection that is still closing"
        )

        await stopping.value
        await starting.value
        session.emit(.publishing)
        try await waitUntil("second broadcast is online") { controller.state == .online }

        #expect(session.publishStartCount == 2, "the broadcast must go live exactly once more")
        #expect(session.publishStopCount == 1)
    }

    @Test("A confirmation from the broadcast being torn down does not put the panel back online")
    func aConfirmationDuringTheGoodbyeRevivesNothing() async throws {
        let session = FakeStreamingSession()
        session.stopPublishingDelay = .milliseconds(300)
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        let stopping = Task { await controller.stopBroadcast() }
        try await waitUntil("the goodbye is on the wire") { session.publishStopCount == 1 }

        // The server is still answering for the broadcast the user has just ended.
        session.emit(.publishing)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(
            controller.state == .offline,
            "a broadcast the user ended came back to life: \(controller.state)"
        )

        await stopping.value
        #expect(controller.state == .offline)
    }

    // MARK: - Losing the connection

    @Test("A dropped connection reconnects on its own and comes back online")
    func reconnectsAfterADrop() async throws {
        let session = FakeStreamingSession()
        // A real pause before the first attempt, so "Reconnecting" is on screen long enough to see.
        let controller = makeController(
            session: session,
            reconnect: ReconnectPolicy(maximumAttempts: 3) { _ in .milliseconds(40) }
        )
        await controller.startCapture()
        await controller.startBroadcast()
        try await waitUntil("online") { controller.state == .online }

        session.emit(.disconnected(.connectionLost))
        try await waitUntil("reconnection started") {
            if case .reconnecting = controller.state { return true }
            return false
        }

        try await waitUntil("back online") { controller.state == .online }

        #expect(session.publishStartCount >= 2)
    }

    @Test("A reconnection that succeeds is not torn down by its own confirmation")
    func earlyPublishingEventDuringReconnectionIsStillSuccess() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        try await waitUntil("online") { controller.state == .online }

        // The reconnection attempt now hangs inside `startPublishing`, the window the server's confirmation arrives in on a real connection.
        session.publishDelay = .milliseconds(80)
        let attemptsBefore = session.publishStartCount
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the reconnection attempt is in flight") {
            session.publishStartCount > attemptsBefore
        }

        // `.publishing` lands first and cancels the reconnection task by putting the broadcast back on air; the attempt returning afterwards must not tear that down again.
        session.emit(.publishing)
        try await waitUntil("back online from the event") { controller.state == .online }
        try? await Task.sleep(for: .milliseconds(200))

        #expect(session.publishStopCount == 0, "the reconnection tore down the stream it just restored")
        #expect(session.isConnectionOpen, "the panel says Online with nothing published")
        #expect(controller.state == .online)
    }

    @Test("A reconnection that never succeeds gives up and says how many times it tried")
    func givesUpAfterTheLastAttempt() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil, .serverUnreachable, .serverUnreachable, .serverUnreachable]
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.emit(.disconnected(.connectionLost))
        try await waitUntil("gave up") {
            controller.state == .failed(.reconnectionGaveUp(attempts: 3))
        }

        #expect(controller.state.isLive == false)
    }

    @Test("Try again after a reconnection gave up puts the broadcast back on air")
    func retryAfterGivingUpGoesBackOnline() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil, .serverUnreachable, .serverUnreachable, .serverUnreachable]
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.emit(.disconnected(.connectionLost))
        try await waitUntil("gave up") {
            controller.state == .failed(.reconnectionGaveUp(attempts: 3))
        }

        // Giving up is the one failure the app declares itself after unwinding its own bookkeeping, so the retry button under it has to still work.
        await controller.retry()

        try await waitUntil("online again after the retry") { controller.state == .online }
        #expect(
            session.captureStartCount == 1,
            "a connection that ran out of attempts had the camera restarted under it"
        )
    }

    @Test("A rejected key mid-broadcast is reported, not retried")
    func doesNotRetryWhatWillFailAgain() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }
        let attemptsBefore = session.publishStartCount

        session.emit(.disconnected(.streamKeyRejected))
        try await waitUntil("failed") { controller.state == .failed(.streamKeyRejected) }

        #expect(session.publishStartCount == attemptsBefore, "no retry for something that cannot succeed")
    }

    @Test("A refused key reported while the reconnection is running does not end the broadcast")
    func aRefusalDuringReconnectionDoesNotEndTheLadder() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil] + Array(repeating: BroadcastFailure.serverUnreachable, count: 3)
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        // Attempts slow enough that the refusal below lands while the reconnection is still working.
        session.publishDelay = .milliseconds(200)
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the first attempt is in flight") { session.publishStartCount == 2 }

        // What a publish handshake closed by an absent network is reported as. The key was accepted when this broadcast went Online, so inside a reconnection this can only be the network.
        session.emit(.disconnected(.streamKeyRejected))
        // Both events go down the same stream in order, so the notice appearing proves the refusal before it was already handled.
        session.emit(.captureInterrupted)
        try await waitUntil("the event after it was handled") { controller.notice == .captureInterrupted }

        #expect(
            controller.state == .reconnecting(attempt: 1),
            "the reconnection was ended by a refusal and the user sent to the setup screen: \(controller.state)"
        )
        try await waitUntil("the reconnection ran out of attempts on its own terms") {
            controller.state == .failed(.reconnectionGaveUp(attempts: 3))
        }
    }

    @Test("A rejected key twice in a row is reported as a rejected key both times")
    func aFailedAttemptLeavesNothingOpen() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [.streamKeyRejected]
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.startBroadcast()
        #expect(controller.state == .failed(.streamKeyRejected))
        #expect(session.isConnectionOpen == false, "a failed attempt left the connection open")

        session.publishFailures = [.streamKeyRejected]
        await controller.retry()

        #expect(
            controller.state == .failed(.streamKeyRejected),
            "the second attempt reported \(controller.state) instead of the real reason"
        )
    }

    @Test("A drop that leaves the connection open still reconnects")
    func reconnectsAfterADropThatLeftTheConnectionOpen() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        try await waitUntil("online") { controller.state == .online }

        // The publish ends but the socket stays up; unless the session closes it, every reconnection attempt is refused before it reaches the server.
        let attemptsBefore = session.publishStartCount
        session.emit(.disconnected(.connectionLost), closingConnection: false)
        try await waitUntil("the first attempt was made") {
            session.publishStartCount > attemptsBefore
        }

        try await waitUntil("back online") { controller.state == .online }
    }

    @Test("Stopping as the last attempt fails leaves the app offline, not in an error")
    func stoppingAsReconnectionGivesUpStaysOffline() async throws {
        let session = FakeStreamingSession()
        // One publish that works, then nothing does: this reconnection runs out of attempts, which has to be checked against a user who stopped.
        session.publishFailures = [nil, .serverUnreachable, .serverUnreachable, .serverUnreachable]
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        // A slow last attempt, so the stop lands between it failing and the reconnection admitting defeat.
        session.publishDelay = .milliseconds(60)
        session.emit(.disconnected(.connectionLost))
        // The initial publish plus three attempts: the third is the last one.
        try await waitUntil("the last attempt is in flight") { session.publishStartCount == 4 }
        await controller.stopBroadcast()

        #expect(controller.state == .offline)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(
            controller.state == .offline,
            "the broadcast the user ended came back as \(controller.state)"
        )
    }

    @Test("Stopping during a reconnection stops it")
    func stoppingCancelsReconnection() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil] + Array(repeating: BroadcastFailure.serverUnreachable, count: 8)
        // A real delay between attempts, unlike other tests: this one needs the controller still mid-reconnection when stop is called.
        let controller = makeController(
            session: session,
            reconnect: ReconnectPolicy(maximumAttempts: 8) { _ in .milliseconds(50) }
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.emit(.disconnected(.connectionLost))
        try await waitUntil("reconnecting") {
            if case .reconnecting = controller.state { return true }
            return false
        }
        await controller.stopBroadcast()

        #expect(controller.state == .offline)
        let attempts = session.publishStartCount
        try? await Task.sleep(for: .milliseconds(200))
        #expect(session.publishStartCount == attempts, "reconnection kept running after stop")
    }

    // MARK: - Waiting for the network rather than for the clock

    @Test("A network that comes back does not have to be waited out")
    func aRestoredNetworkEndsTheWait() async throws {
        let session = FakeStreamingSession()
        let connectivity = FakeConnectivityMonitor()
        let controller = makeController(
            session: session,
            reconnect: Self.patientReconnect,
            connectivity: connectivity
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }
        #expect(connectivity.isWatching == false, "the network is watched with nothing to reconnect")

        let attemptsBefore = session.publishStartCount
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the reconnection is waiting") {
            if case .reconnecting = controller.state { return true }
            return false
        }
        try await waitUntil("the network is being watched") { connectivity.isWatching }

        // The network goes and comes back while five seconds of backoff are still on the clock, so a new attempt now can only mean the wait was cut short.
        connectivity.send(isSatisfied: false)
        connectivity.send(isSatisfied: true)

        try await waitUntil("the next attempt is made at once") {
            session.publishStartCount > attemptsBefore
        }
        try await waitUntil("back online") { controller.state == .online }
        try await waitUntil("the watching stops with the reconnection") { !connectivity.isWatching }
    }

    @Test("A network that comes back during an attempt shortens the wait that follows it")
    func aRestoreDuringAnAttemptShortensTheNextWait() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil] + Array(repeating: BroadcastFailure.serverUnreachable, count: 3)
        let connectivity = FakeConnectivityMonitor()
        let controller = makeController(
            session: session,
            reconnect: Self.patientAfterTheFirstAttempt,
            connectivity: connectivity
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        // An attempt that outlives the restore, matching a real phone: the connect already on the wire sits on the library's timer while the network returns.
        session.publishDelay = .milliseconds(200)
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the first attempt is in flight") { session.publishStartCount == 2 }
        try await waitUntil("the network is being watched") { connectivity.isWatching }

        connectivity.send(isSatisfied: false)
        connectivity.send(isSatisfied: true)

        // Five seconds of backoff stand between this failure and the next attempt, so a second attempt inside the test window can only have come from the restore.
        try await waitUntil("the wait after the attempt is skipped") { session.publishStartCount == 3 }
    }

    @Test("A network that is still up skips every wait, not only the first one after it came back")
    func aRestoredNetworkKeepsSkippingWaits() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil] + Array(repeating: BroadcastFailure.serverUnreachable, count: 3)
        let connectivity = FakeConnectivityMonitor()
        let controller = makeController(
            session: session,
            reconnect: Self.patientAfterTheFirstAttempt,
            connectivity: connectivity
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.publishDelay = .milliseconds(200)
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the first attempt is in flight") { session.publishStartCount == 2 }
        try await waitUntil("the network is being watched") { connectivity.isWatching }

        connectivity.send(isSatisfied: false)
        connectivity.send(isSatisfied: true)
        try await waitUntil("the wait after the attempt is skipped") { session.publishStartCount == 3 }

        // No further path update: the network came back once and is still there, so neither attempt has a backoff to wait out.
        try await waitUntil("the wait after the next failure is skipped as well") {
            session.publishStartCount == 4
        }
    }

    @Test("A wait that was skipped still moves the panel to the attempt now on the wire")
    func aSkippedWaitStillNamesTheAttemptInFlight() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil] + Array(repeating: BroadcastFailure.serverUnreachable, count: 3)
        let connectivity = FakeConnectivityMonitor()
        let controller = makeController(
            session: session,
            reconnect: Self.patientAfterTheFirstAttempt,
            connectivity: connectivity
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        // The restore lands inside the first attempt, so the wait behind it is skipped rather than counted down — the case where the next attempt would otherwise be made under the previous attempt's number.
        session.publishDelay = .milliseconds(200)
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the first attempt is in flight") { session.publishStartCount == 2 }
        try await waitUntil("the network is being watched") { connectivity.isWatching }
        connectivity.send(isSatisfied: false)
        connectivity.send(isSatisfied: true)

        try await waitUntil("the second attempt is in flight") { session.publishStartCount == 3 }

        #expect(
            controller.state == .reconnecting(attempt: 2),
            "the panel says \(controller.state) while the second attempt is on the wire"
        )
        #expect(controller.secondsUntilNextAttempt == nil, "an attempt already on the wire is counted down to")
    }

    @Test("An attempt is not fired on a path that is reported back but cannot carry it yet")
    func theAttemptAfterARestoreWaitsForThePathToSettle() async throws {
        let session = FakeStreamingSession()
        let connectivity = FakeConnectivityMonitor()
        // Built without the helper, so the settle is the one the app ships with: a path the system reports as satisfied is not yet a path that resolves a host.
        let controller = BroadcastController(
            endpoint: Self.endpoint,
            session: session,
            permissions: StubMediaPermissions(),
            reconnectPolicy: Self.patientReconnect,
            connectivity: connectivity,
            countdownTick: Self.instantCountdownTick
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        let attemptsBefore = session.publishStartCount
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the network is being watched") { connectivity.isWatching }

        connectivity.send(isSatisfied: false)
        connectivity.send(isSatisfied: true)
        try? await Task.sleep(for: .milliseconds(150))

        #expect(
            session.publishStartCount == attemptsBefore,
            "the attempt went out on the restored edge, where a phone still has no route and no DNS"
        )

        // Still nothing like the five seconds of backoff the skip exists to remove.
        try await waitUntil("the attempt is made once the path has had its moment") {
            session.publishStartCount > attemptsBefore
        }
        try await waitUntil("back online") { controller.state == .online }
    }

    @Test("A network that goes away again brings the waiting back")
    func aSecondLossEndsTheSkipping() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil] + Array(repeating: BroadcastFailure.serverUnreachable, count: 3)
        let connectivity = FakeConnectivityMonitor()
        let controller = makeController(
            session: session,
            reconnect: Self.patientAfterTheFirstAttempt,
            connectivity: connectivity
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.publishDelay = .milliseconds(300)
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the first attempt is in flight") { session.publishStartCount == 2 }
        try await waitUntil("the network is being watched") { connectivity.isWatching }

        connectivity.send(isSatisfied: false)
        connectivity.send(isSatisfied: true)
        // ...and gone again before the attempt in flight has even failed, so what follows is a wait for a network that is away.
        connectivity.send(isSatisfied: false)

        let attemptsBefore = session.publishStartCount
        try? await Task.sleep(for: .milliseconds(600))

        #expect(
            session.publishStartCount == attemptsBefore,
            "the backoff was skipped for a network that had gone away again"
        )
    }

    @Test("A network that never went away does not shorten the wait")
    func aPathThatWasNeverLostChangesNothing() async throws {
        let session = FakeStreamingSession()
        let connectivity = FakeConnectivityMonitor()
        let controller = makeController(
            session: session,
            reconnect: Self.patientReconnect,
            connectivity: connectivity
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        let attemptsBefore = session.publishStartCount
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the network is being watched") { connectivity.isWatching }

        // The first is what every monitor reports the moment it starts; neither is a network coming back, so neither may buy an early attempt.
        connectivity.send(isSatisfied: true)
        connectivity.send(isSatisfied: true)
        try? await Task.sleep(for: .milliseconds(300))

        #expect(
            session.publishStartCount == attemptsBefore,
            "the backoff was skipped for a network that was never away"
        )
    }

    @Test("A network that keeps coming back does not buy more attempts")
    func restoresDoNotExtendTheAttemptBudget() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil] + Array(repeating: BroadcastFailure.serverUnreachable, count: 8)
        let connectivity = FakeConnectivityMonitor()
        let controller = makeController(
            session: session,
            reconnect: Self.patientReconnect,
            connectivity: connectivity
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        // A path that flaps for the whole reconnection: every wait is skipped, but it still has to run out of attempts and say so.
        let flapping = Task { @MainActor in
            while !Task.isCancelled {
                connectivity.send(isSatisfied: false)
                connectivity.send(isSatisfied: true)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { flapping.cancel() }

        session.emit(.disconnected(.connectionLost))
        try await waitUntil("gave up") {
            controller.state == .failed(.reconnectionGaveUp(attempts: 3))
        }

        #expect(session.publishStartCount == 4, "the initial publish and three attempts, no more")
        try await waitUntil("the watching stops with the reconnection") { !connectivity.isWatching }
    }

    @Test("A network coming back does not resurrect a broadcast that ended")
    func aRestoredNetworkStartsNothingAfterAFailure() async throws {
        let session = FakeStreamingSession()
        let connectivity = FakeConnectivityMonitor()
        let controller = makeController(
            session: session,
            reconnect: Self.patientReconnect,
            connectivity: connectivity
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.emit(.disconnected(.streamKeyRejected))
        try await waitUntil("failed") { controller.state == .failed(.streamKeyRejected) }
        let attemptsBefore = session.publishStartCount

        #expect(connectivity.isWatching == false, "the network is watched with nothing to reconnect")
        connectivity.send(isSatisfied: false)
        connectivity.send(isSatisfied: true)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(session.publishStartCount == attemptsBefore, "a path event went on air by itself")
        #expect(controller.state == .failed(.streamKeyRejected))
    }

    @Test("Stopping during a reconnection stops watching the network too")
    func stoppingEndsTheWatching() async throws {
        let session = FakeStreamingSession()
        let connectivity = FakeConnectivityMonitor()
        let controller = makeController(
            session: session,
            reconnect: Self.patientReconnect,
            connectivity: connectivity
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the network is being watched") { connectivity.isWatching }

        await controller.stopBroadcast()

        #expect(controller.state == .offline)
        try await waitUntil("the watching stops with the reconnection") { !connectivity.isWatching }
    }

    // MARK: - Counting the wait down

    @Test("The wait before the next attempt is counted down second by second")
    func theWaitIsCountedDown() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session, reconnect: Self.patientReconnect)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }
        #expect(controller.secondsUntilNextAttempt == nil, "a broadcast that is up counts nothing down")

        session.emit(.disconnected(.connectionLost))

        var seen: [Int] = []
        try await waitUntil("the countdown reaches its last second") {
            if let seconds = controller.secondsUntilNextAttempt, seen.last != seconds {
                seen.append(seconds)
            }
            return seen.last == 1
        }

        #expect(seen == [5, 4, 3, 2, 1], "the countdown went \(seen)")
        await controller.stopBroadcast()
    }

    @Test("A network that comes back takes the countdown off the screen at once")
    func aRestoredNetworkClearsTheCountdown() async throws {
        let session = FakeStreamingSession()
        let connectivity = FakeConnectivityMonitor()
        let controller = makeController(
            session: session,
            reconnect: Self.patientReconnect,
            connectivity: connectivity
        )
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        // An attempt slow enough to be caught in flight, which is where the countdown must already be gone.
        session.publishDelay = .milliseconds(200)
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the countdown is on screen") { controller.secondsUntilNextAttempt == 5 }
        try await waitUntil("the network is being watched") { connectivity.isWatching }

        let attemptsBefore = session.publishStartCount
        connectivity.send(isSatisfied: false)
        connectivity.send(isSatisfied: true)

        // Five seconds of backoff stand behind that number, so an attempt this soon can only mean the wait was cut short.
        try await waitUntil("the next attempt is made at once") {
            session.publishStartCount > attemptsBefore
        }
        #expect(
            controller.secondsUntilNextAttempt == nil,
            "the countdown outlived the wait it was counting"
        )

        try await waitUntil("back online") { controller.state == .online }
        #expect(controller.secondsUntilNextAttempt == nil, "a broadcast back on air still counts something down")
    }

    @Test("Nothing counts down while an attempt is on the wire")
    func noCountdownDuringAnAttempt() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil] + Array(repeating: BroadcastFailure.serverUnreachable, count: 3)
        let controller = makeController(session: session, reconnect: Self.aSecondThenPatient)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.publishDelay = .milliseconds(200)
        session.emit(.disconnected(.connectionLost))
        // A countdown really was on screen, so what follows is it going away rather than never arriving.
        try await waitUntil("the wait is counted down") { controller.secondsUntilNextAttempt == 1 }
        try await waitUntil("the first attempt is in flight", timeout: .seconds(3)) {
            session.publishStartCount == 2
        }

        #expect(
            controller.secondsUntilNextAttempt == nil,
            "the screen counts down to an attempt that is already being made"
        )

        try await waitUntil("the wait after it is counted down") { controller.secondsUntilNextAttempt == 5 }
        await controller.stopBroadcast()
    }

    @Test("Running out of attempts leaves nothing counting down")
    func givingUpClearsTheCountdown() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil, .serverUnreachable]
        let controller = makeController(session: session, reconnect: Self.oneAttemptAfterASecond)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the countdown is on screen") { controller.secondsUntilNextAttempt == 1 }
        try await waitUntil("gave up") {
            controller.state == .failed(.reconnectionGaveUp(attempts: 1))
        }

        #expect(controller.secondsUntilNextAttempt == nil, "a countdown was left under the error card")
    }

    @Test("Stopping during the wait takes the countdown away with it")
    func stoppingClearsTheCountdown() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session, reconnect: Self.patientReconnect)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the countdown is on screen") { controller.secondsUntilNextAttempt != nil }

        await controller.stopBroadcast()

        #expect(controller.state == .offline)
        #expect(controller.secondsUntilNextAttempt == nil)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(
            controller.secondsUntilNextAttempt == nil,
            "the countdown kept ticking after the broadcast was stopped"
        )
    }

    // MARK: - Controls

    @Test("Muting the microphone reaches the session")
    func mutesTheMicrophone() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.toggleMicrophone()
        #expect(controller.isMicrophoneMuted)
        #expect(session.isMicrophoneMuted)

        await controller.toggleMicrophone()
        #expect(controller.isMicrophoneMuted == false)
        #expect(session.isMicrophoneMuted == false)
    }

    @Test("Switching to a camera the phone does not have says so and keeps the current one")
    func missingFrontCameraIsHandled() async {
        let session = FakeStreamingSession()
        session.switchCameraFailure = .cameraMissing(.front)
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.switchCamera()

        #expect(controller.cameraFacing == .back, "we stay on the camera that works")
        #expect(controller.notice == .cameraMissing(.front))
        #expect(controller.state == .offline, "a camera problem is not a broadcast problem")
    }

    @Test("Switching cameras works while live and does not interrupt the broadcast")
    func switchesCameraWhileLive() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        await controller.switchCamera()

        #expect(controller.cameraFacing == .front)
        #expect(session.facing == .front)
        #expect(controller.state == .online)
    }

    // MARK: - Teardown

    @Test("Shutting down closes the camera and the connection")
    func shutDownReleasesEverything() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        await controller.shutDown()

        #expect(session.publishStopCount == 1)
        #expect(session.captureStopCount == 1)
        #expect(controller.isCapturing == false)
        #expect(controller.state == .offline)
    }

    // MARK: - Leaving the app and coming back

    @Test("A camera that was running when the app went away comes back on its own")
    func returningRestoresACameraThatWasRunning() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.suspendForBackground()
        #expect(controller.isCapturing == false)

        await controller.restoreAfterForeground()

        #expect(controller.isCapturing)
        #expect(session.captureResumeCount == 1)
        #expect(session.captureStartCount == 1, "the pipeline was rebuilt instead of picked back up")
    }

    @Test("A camera that was off is not started by a return to the foreground")
    func returningStartsNothingThatWasNotRunning() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)

        await controller.suspendForBackground()
        await controller.restoreAfterForeground()

        #expect(controller.isCapturing == false)
        #expect(session.captureStartCount == 0)
    }

    @Test("A broadcast cut short by the app going away picks itself back up")
    func returningResumesABroadcastThatWasOnAir() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        await controller.suspendForBackground()
        #expect(controller.state == .offline)

        await controller.restoreAfterForeground()

        try await waitUntil("online again") { controller.state == .online }
        #expect(controller.isCapturing)
        #expect(session.captureStartCount == 1, "a second pipeline is a second connection to the same key")
        #expect(session.isPipelineAlive)
        #expect(session.publishStartCount == 2)
    }

    /// The ladder backs off before every attempt, including the first — which on a return from the background is a wait for a failure that never happened. The path never dropped, so the skip that a returning network buys cannot fire here either.
    @Test("A resume publishes at once instead of sitting out a backoff nothing earned")
    func aResumeDoesNotWaitOutTheFirstBackoff() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session, reconnect: Self.patientReconnect)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        await controller.suspendForBackground()
        await controller.restoreAfterForeground()

        // Five seconds of backoff stand in front of the first attempt, so a publish inside the test window can only mean it was never waited out.
        try await waitUntil("republished at once") { session.publishStartCount == 2 }
        try await waitUntil("online again") { controller.state == .online }
        #expect(controller.secondsUntilNextAttempt == nil)
    }

    @Test("A drop mid-broadcast still backs off before its first attempt")
    func anOrdinaryReconnectionStillWaitsBeforeTheFirstAttempt() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session, reconnect: Self.patientReconnect)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.emit(.disconnected(.connectionLost))

        // The countdown is only on screen while a backoff is actually being waited out.
        try await waitUntil("counting down to the first attempt") { controller.secondsUntilNextAttempt != nil }
        #expect(controller.state == .reconnecting(attempt: 1))
        #expect(session.publishStartCount == 1, "a server that just hung up is given a second before it is asked again")
    }

    /// The resume goes through the reconnection ladder, so a server that will not take the stream back ends on the card that offers Try again — never on "Edit stream key", which is what a cold start would have made of the same refusal.
    @Test("A resume the server keeps refusing gives up like a reconnection, not like a bad key")
    func aRefusedResumeEndsAsAReconnectionThatGaveUp() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.publishFailures = Array(repeating: .streamKeyRejected, count: 3)
        await controller.suspendForBackground()
        await controller.restoreAfterForeground()

        try await waitUntil("given up") { controller.state.failure != nil }
        #expect(controller.state == .failed(.reconnectionGaveUp(attempts: 3)))
        #expect(controller.isCapturing, "the camera stays up so Try again has something to publish")
    }

    @Test("A camera that will not come back does not go on to resume the broadcast")
    func aFailedCameraOnTheWayBackResumesNothing() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        await controller.suspendForBackground()
        session.captureFailure = .cameraUnavailable
        await controller.restoreAfterForeground()

        #expect(controller.isCapturing == false)
        #expect(controller.state == .failed(.cameraUnavailable))
        #expect(session.publishStartCount == 1)
    }

    /// Giving the devices back runs while iOS is freezing the app, so it routinely finishes only after the return — the restore must wait for it instead of reading flags that are not armed yet. This is the black-screen-after-return bug from his device pass.
    @Test("A return that lands before the teardown has finished still restores everything")
    func aFastReturnStillRestores() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.suspendCaptureDelay = .milliseconds(200)
        let suspend = Task { await controller.suspendForBackground() }
        try? await Task.sleep(for: .milliseconds(10))
        await controller.restoreAfterForeground()
        await suspend.value

        try await waitUntil("online again") { controller.state == .online }
        #expect(controller.isCapturing)
        #expect(session.publishStartCount == 2)
    }

    @Test("The duration keeps counting across a background round trip instead of restarting")
    func theDurationSurvivesTheRoundTrip() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        // Real time, deliberately: the duration is measured against the wall clock.
        try? await Task.sleep(for: .milliseconds(1100))
        await controller.suspendForBackground()
        await controller.restoreAfterForeground()
        try await waitUntil("online again") { controller.state == .online }

        #expect(controller.elapsedSeconds >= 1, "the resumed broadcast is the same broadcast, not a new one")
    }

    /// The panel shows the duration all through `.reconnecting`, and `goOnline()` is the first thing that would recompute it — so without a recount at the restore the resumed broadcast is watched from 00:00 until the ladder succeeds, then jumps.
    @Test("The resumed duration is already right while the ladder is still climbing")
    func theResumedDurationIsRightBeforeItGoesOnlineAgain() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session, reconnect: Self.patientReconnect)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        try? await Task.sleep(for: .milliseconds(1100))
        await controller.suspendForBackground()
        await controller.restoreAfterForeground()

        #expect(controller.state.isLive == false, "measured before goOnline() could have done it for us")
        #expect(controller.elapsedSeconds >= 1)
    }

    /// One RTMP session per broadcast. Twitch takes one live publisher per stream key, so a second connection with the same key displaces the first — and a session displaced by its own replacement is not a drop the server holds open, it is a new stream with the uptime back at zero.
    @Test("Backgrounding mid-broadcast keeps the session and gives back only the devices")
    func backgroundingKeepsTheSession() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        await controller.suspendForBackground()

        #expect(session.captureSuspendCount == 1)
        #expect(session.publishStopCount == 0, "a goodbye here would end the stream on the server for good")
        #expect(session.captureStopCount == 0, "taking the pipeline down is what forces a second connection")
        #expect(session.isPipelineAlive)
    }

    @Test("A return the server is still holding goes back Online without publishing again")
    func aHeldSessionGoesStraightBackOnline() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.keepsPublishingWhileSuspended = true
        await controller.suspendForBackground()
        await controller.restoreAfterForeground()
        // Long enough for a ladder that should not be running to have published, so the count below is a fact and not a head start.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(controller.state == .online, "nothing on the wire ended, so there is nothing to reconnect")
        #expect(session.publishStartCount == 1, "publishing again is exactly what starts a second stream")
        #expect(session.isPipelineAlive)
    }

    @Test("The duration keeps counting across a round trip the server held onto")
    func theDurationSurvivesAHeldRoundTrip() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        // Real time, deliberately: the duration is measured against the wall clock.
        try? await Task.sleep(for: .milliseconds(1100))
        session.keepsPublishingWhileSuspended = true
        await controller.suspendForBackground()
        await controller.restoreAfterForeground()

        #expect(controller.state == .online)
        #expect(controller.elapsedSeconds >= 1, "the broadcast the server never lost was restarted at zero")
    }

    /// A server that hung up while the process was frozen sends a FIN the socket only reads once the app is running again, so the question asked at the moment of the return is answered from a connection that has not heard the news yet. Without a second look the panel says Online over a dead socket until the library gets round to saying otherwise.
    @Test("A held session that turns out to be dead is noticed and reconnected")
    func aStaleHeldSessionIsCaughtAndReconnected() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.keepsPublishingWhileSuspended = true
        await controller.suspendForBackground()
        await controller.restoreAfterForeground()
        #expect(controller.state == .online, "the session answered that it was still held")

        session.keepsPublishingWhileSuspended = false

        try await waitUntil("the dead session is published again") { session.publishStartCount > 1 }
        try await waitUntil("back online") { controller.state == .online }
    }

    /// Measured on the device, in both round trips of the diagnostic run: the socket the system reclaimed while the process was frozen is still reported as open, RTMP refuses to dial a connection it believes is open, and that refusal comes back in the same millisecond. The rung it costs is a rung and the whole backoff behind it — 2 s of the user's picture, spent on the app's own leftover.
    @Test("The first rung of the ladder is not spent on the connection the background stay left behind")
    func theLadderDoesNotSpendARungOnTheLeftoverConnection() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session, reconnect: Self.patientAfterTheFirstAttempt)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.leavesTheConnectionOpenAfterTheDrop = true
        await controller.suspendForBackground()
        await controller.restoreAfterForeground()

        // Every rung after the first waits five seconds here, so a wasted first rung is a test that never comes back online.
        try await waitUntil("online again on the first attempt") { controller.state == .online }
        #expect(
            session.publishStopCount == 1,
            "the ladder dialled without closing the connection the app already knew the server had let go of"
        )
        #expect(
            session.publishStartCount == 2,
            "the broadcast was published \(session.publishStartCount) times, one of them into a connection that could only refuse it"
        )
    }

    @Test("A session the server really is holding is left alone")
    func aHealthyHeldSessionIsNotDisturbedByTheRecheck() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.keepsPublishingWhileSuspended = true
        await controller.suspendForBackground()
        await controller.restoreAfterForeground()
        // Well past the re-check window, so the counts below are a fact rather than a head start.
        try? await Task.sleep(for: .milliseconds(200))

        #expect(controller.state == .online)
        #expect(session.publishStartCount == 1, "publishing again is exactly what starts a second stream")
    }

    @Test("Leaving the screen takes the re-check with it")
    func theRecheckDoesNothingAfterAShutdown() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.keepsPublishingWhileSuspended = true
        await controller.suspendForBackground()
        await controller.restoreAfterForeground()
        await controller.shutDown()
        session.keepsPublishingWhileSuspended = false
        try? await Task.sleep(for: .milliseconds(200))

        #expect(controller.state == .offline)
        #expect(session.publishStartCount == 1, "a broadcast the user ended is not one to reconnect")
    }

    @Test("The Stop button and leaving the screen still say goodbye politely")
    func deliberateExitsStillSayGoodbye() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        await controller.stopBroadcast()
        await controller.shutDown()

        #expect(session.publishStopCount >= 1)
        #expect(session.captureSuspendCount == 0, "a deliberate exit does not intend to come back")
        #expect(session.isPipelineAlive == false)
    }

    @Test("The clock overlay survives the background round trip")
    func theClockOverlaySurvivesTheRoundTrip() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.toggleClockOverlay()
        #expect(session.overlay != nil)

        await controller.suspendForBackground()
        #expect(session.overlay == nil, "nothing may keep drawing while the app is away")

        await controller.restoreAfterForeground()

        #expect(controller.isClockOverlayVisible)
        #expect(session.overlay != nil)
    }

    @Test("A clock that was off stays off after the round trip")
    func aClockThatWasOffStaysOff() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.suspendForBackground()
        await controller.restoreAfterForeground()

        #expect(controller.isClockOverlayVisible == false)
        #expect(session.overlay == nil)
    }

    @Test("A muted microphone stays muted across the background round trip")
    func mutedMicrophoneSurvivesTheRoundTrip() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.toggleMicrophone()
        #expect(controller.isMicrophoneMuted)

        await controller.suspendForBackground()
        await controller.restoreAfterForeground()

        #expect(controller.isMicrophoneMuted, "the mute did not survive the round trip")
        #expect(session.isMicrophoneMuted, "the mute did not survive the round trip")
    }

    @Test("An unmuted microphone stays unmuted across the background round trip")
    func unmutedMicrophoneStaysUnmuted() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.suspendForBackground()
        await controller.restoreAfterForeground()

        #expect(controller.isMicrophoneMuted == false)
        #expect(session.isMicrophoneMuted == false)
    }

    @Test("A muted microphone stays muted even when only the camera was on")
    func mutedMicrophoneSurvivesWithNothingOnAir() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.toggleMicrophone()
        #expect(controller.isMicrophoneMuted)

        await controller.suspendForBackground()
        await controller.restoreAfterForeground()

        #expect(controller.isCapturing)
        #expect(controller.state == .offline)
        #expect(controller.isMicrophoneMuted, "the mute did not survive the round trip")
        #expect(session.isMicrophoneMuted, "the mute did not survive the round trip")
    }

    @Test("A camera that was on with nothing on air comes back alone")
    func returningWithNothingOnAirPublishesNothing() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.suspendForBackground()
        await controller.restoreAfterForeground()

        #expect(controller.isCapturing)
        #expect(controller.state == .offline)
        #expect(session.publishStartCount == 0)
    }

    @Test("Leaving the screen owes no restore")
    func shuttingDownAloneOwesNoRestore() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.shutDown()
        await controller.restoreAfterForeground()

        #expect(controller.isCapturing == false)
        #expect(session.captureStartCount == 1)
    }

    /// A permission alert or Control Centre makes the app inactive without ever backgrounding it, so the camera was never torn down and there is nothing to restore.
    @Test("Coming back from an interruption that tore nothing down leaves the running camera alone")
    func returningWithoutHavingBeenBackgroundedTouchesNothing() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.restoreAfterForeground()

        #expect(controller.isCapturing)
        #expect(session.captureStartCount == 1)
    }

    @Test("The restore is owed once, so a second return without a second backgrounding starts nothing")
    func theRestoreIsOwedOnce() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.suspendForBackground()

        await controller.restoreAfterForeground()
        await controller.shutDown()
        await controller.restoreAfterForeground()

        #expect(controller.isCapturing == false)
        #expect(session.captureStartCount == 1)
        #expect(session.captureResumeCount == 1)
    }

    // MARK: - Telling the screen a restore is under way

    @Test("Backgrounding a running camera puts the screen into its restoring state")
    func suspendingMarksTheScreenAsRestoring() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.suspendForBackground()

        #expect(controller.isRestoring)
        #expect(controller.isCapturing == false, "which is exactly the moment the camera-off screen would flash")
    }

    /// The flag is what the screen reads the instant it comes back, and the return routinely lands inside the frozen goodbye — so it cannot be armed by the teardown that has not finished.
    @Test("The restoring state is up before the teardown behind it has finished")
    func restoringIsUpBeforeTheTeardownFinishes() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.suspendCaptureDelay = .milliseconds(200)
        let suspend = Task { await controller.suspendForBackground() }
        try? await Task.sleep(for: .milliseconds(10))
        #expect(controller.isRestoring, "a return landing here must not find the flag still false")

        await suspend.value
        #expect(controller.isRestoring, "and it stays up until the return has put the screen back")
    }

    @Test("The restoring state ends when the return has put the screen back")
    func restoringEndsWithTheRestore() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.suspendForBackground()

        await controller.restoreAfterForeground()

        #expect(controller.isRestoring == false)
        #expect(controller.isCapturing)
    }

    @Test("A camera that will not come back still ends the restoring state, so the failure card is reachable")
    func aFailedRestoreStillEndsTheRestoringState() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.suspendForBackground()
        session.captureFailure = .cameraUnavailable

        await controller.restoreAfterForeground()

        #expect(controller.isRestoring == false)
        #expect(controller.state == .failed(.cameraUnavailable))
    }

    @Test("Leaving the screen leaves nothing restoring behind")
    func shuttingDownClearsTheRestoringState() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.suspendForBackground()

        await controller.shutDown()

        #expect(controller.isRestoring == false)
    }

    @Test("A camera that was off is never shown a restore in progress")
    func aCameraThatWasOffNeverRestores() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)

        await controller.suspendForBackground()
        #expect(controller.isRestoring == false)

        await controller.restoreAfterForeground()
        #expect(controller.isRestoring == false)
    }

    // MARK: - What the screen shows

    @Test("The status label never says Online unless the stream is live")
    func labelMatchesReality() {
        #expect(BroadcastState.offline.label == "Offline")
        #expect(BroadcastState.connecting.label == "Connecting")
        #expect(BroadcastState.online.label == "Online")
        #expect(BroadcastState.reconnecting(attempt: 2).label == "Reconnecting")
        #expect(BroadcastState.failed(.connectionLost).label == "Error")

        for state: BroadcastState in [.offline, .connecting, .reconnecting(attempt: 1), .failed(.connectionLost)] {
            #expect(state.isLive == false, "\(state) must not read as live")
        }
        #expect(BroadcastState.online.isLive)
    }

    @Test("Durations are formatted the way a broadcaster reads them")
    func formatsDuration() {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        #expect(controller.formattedDuration == "00:00")

        #expect(BroadcastController.formatDuration(seconds: 5) == "00:05")
        #expect(BroadcastController.formatDuration(seconds: 83) == "01:23")
        #expect(BroadcastController.formatDuration(seconds: 3599) == "59:59")
        #expect(BroadcastController.formatDuration(seconds: 3600) == "1:00:00", "the hour has to appear")
        #expect(BroadcastController.formatDuration(seconds: 3723) == "1:02:03")
        #expect(BroadcastController.formatDuration(seconds: 36_000) == "10:00:00")
    }

    // MARK: - Things that only go wrong under a second tap or a bad moment

    @Test("A broadcast started after the app was backgrounded still goes Online, and still hears the server")
    func eventsSurviveAShutdown() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)

        await controller.startCapture()
        await controller.startBroadcast()
        try await waitUntil("online the first time") { controller.state == .online }

        // This is what backgrounding the app does.
        await controller.shutDown()

        await controller.startCapture()
        // A slow server, so going Online can only come from the event, not the request returning — the half that goes silent when the stream is torn down.
        session.publishDelay = .seconds(2)
        let starting = Task { await controller.startBroadcast() }
        try await waitUntil("connecting") { controller.state == .connecting }

        session.emit(.publishing)
        try await waitUntil("online from the event", timeout: .milliseconds(500)) {
            controller.state == .online
        }

        await starting.value
    }

    @Test("A second drop in the same broadcast reconnects too")
    func aSecondDropStillReconnects() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)

        await controller.startCapture()
        await controller.startBroadcast()
        try await waitUntil("online") { controller.state == .online }
        let beforeFirstDrop = session.publishStartCount

        session.emit(.disconnected(.connectionLost))
        try await waitUntil("first reconnection attempted") {
            session.publishStartCount > beforeFirstDrop
        }
        try await waitUntil("online again after the first drop") { controller.state == .online }
        let afterFirstDrop = session.publishStartCount

        session.emit(.disconnected(.connectionLost))
        try await waitUntil("second reconnection attempted") {
            session.publishStartCount > afterFirstDrop
        }
    }

    @Test("A camera that will not switch does not make a live broadcast look dead")
    func cameraErrorWhileLiveDoesNotFakeAFailure() async throws {
        let session = FakeStreamingSession()
        session.switchCameraFailure = .cameraMissing(.front)
        let controller = makeController(session: session)

        await controller.startCapture()
        await controller.startBroadcast()
        try await waitUntil("online") { controller.state == .online }

        await controller.switchCamera()

        #expect(
            controller.state == .online,
            "the broadcast is still publishing but the status says \(controller.state)"
        )
        #expect(controller.notice == .cameraMissing(.front), "the user is told nothing at all")
    }

    @Test("Try again after a camera error does not start a broadcast")
    func retryAfterCameraErrorDoesNotGoLive() async {
        let session = FakeStreamingSession()
        session.switchCameraFailure = .cameraMissing(.front)
        let controller = makeController(session: session)

        await controller.startCapture()
        await controller.switchCamera()
        #expect(controller.notice == .cameraMissing(.front))

        let publishesBefore = session.publishStartCount
        await controller.retry()

        #expect(
            session.publishStartCount == publishesBefore,
            "asking to retry a camera error put the user on air"
        )
    }

    @Test("Try again after a camera failure retries the camera, not the broadcast")
    func retryAfterACaptureFailureRetriesCapture() async {
        let session = FakeStreamingSession()
        session.captureFailure = .cameraUnavailable
        let controller = makeController(session: session)

        await controller.startCapture()
        #expect(controller.state == .failed(.cameraUnavailable))

        session.captureFailure = nil
        await controller.retry()

        #expect(controller.isCapturing, "the camera was never tried again")
        #expect(session.publishStartCount == 0, "retrying a camera failure went on air instead")
    }

    @Test("Try again after a broadcast failure retries the broadcast")
    func retryAfterABroadcastFailureRetriesTheBroadcast() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [.serverUnreachable]
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.startBroadcast()
        #expect(controller.state == .failed(.serverUnreachable))

        await controller.retry()

        try await waitUntil("online after the retry") { controller.state == .online }
        #expect(session.captureStartCount == 1, "the camera was restarted for no reason")
    }

    @Test("Stopping while Connecting really stops")
    func stoppingDuringConnectingStops() async throws {
        let session = FakeStreamingSession()
        session.publishDelay = .milliseconds(120)
        let controller = makeController(session: session)
        await controller.startCapture()

        let starting = Task { await controller.startBroadcast() }
        try await waitUntil("connecting") { controller.state == .connecting }

        await controller.stopBroadcast()
        #expect(controller.state == .offline)

        await starting.value
        #expect(session.publishStopCount >= 1)
        #expect(controller.state == .offline)

        // The server confirms the publish the user already cancelled.
        session.emit(.publishing)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(
            controller.state == .offline,
            "a cancelled broadcast came back to life: \(controller.state)"
        )
    }

    @Test("Double-tapping the camera button opens the camera once")
    func doubleTapOpensCameraOnce() async {
        let session = FakeStreamingSession()
        session.captureDelay = .milliseconds(100)
        let controller = makeController(session: session)

        async let first: Void = controller.startCapture()
        try? await Task.sleep(for: .milliseconds(10))
        async let second: Void = controller.startCapture()
        _ = await (first, second)

        #expect(
            session.captureStartCount == 1,
            "the camera was opened \(session.captureStartCount) times"
        )
    }

    @Test("Backgrounding the app while the camera is opening does not leave a preview behind")
    func shutDownWhileStartingCaptureLeavesTheCameraOff() async {
        let session = FakeStreamingSession()
        // The camera is still opening when the app backgrounds: the session tears down what it built and returns without throwing, so only the generation can tell this start its result is unwanted.
        session.captureDelay = .milliseconds(100)
        let controller = makeController(session: session)

        async let starting: Void = controller.startCapture()
        try? await Task.sleep(for: .milliseconds(20))
        await controller.shutDown()
        #expect(controller.isCapturing == false)

        await starting

        #expect(
            controller.isCapturing == false,
            "the screen shows a preview and a full set of controls with no pipeline behind them"
        )
        #expect(controller.state == .offline)
    }

    @Test("A camera that fails after the app was backgrounded does not leave an error card")
    func aCaptureFailureAfterShutDownIsNotShown() async {
        let session = FakeStreamingSession()
        session.captureDelay = .milliseconds(100)
        session.captureFailure = .cameraUnavailable
        let controller = makeController(session: session)

        async let starting: Void = controller.startCapture()
        try? await Task.sleep(for: .milliseconds(20))
        await controller.shutDown()

        await starting

        #expect(
            controller.state == .offline,
            "a user who left the screen is shown \(controller.state) about a camera already closed"
        )
        #expect(controller.isCapturing == false)
    }

    @Test("Double-tapping the camera button switches the camera once")
    func doubleTapSwitchesCameraOnce() async {
        let session = FakeStreamingSession()
        session.switchCameraDelay = .milliseconds(100)
        let controller = makeController(session: session)
        await controller.startCapture()

        async let first: Void = controller.switchCamera()
        try? await Task.sleep(for: .milliseconds(10))
        async let second: Void = controller.switchCamera()
        _ = await (first, second)

        #expect(
            session.switchCameraCount == 1,
            "the camera was switched \(session.switchCameraCount) times"
        )
        #expect(controller.cameraFacing == .front)
        #expect(session.facing == .front)
    }

    @Test("A reconnection that succeeds on a later attempt comes back online")
    func reconnectionSucceedsOnALaterAttempt() async throws {
        let session = FakeStreamingSession()
        session.publishFailures = [nil, .serverUnreachable, .serverUnreachable]
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        try await waitUntil("online") { controller.state == .online }

        session.emit(.disconnected(.connectionLost))
        // 1 initial publish + 2 refused attempts + the one that worked.
        try await waitUntil("three reconnection attempts") { session.publishStartCount == 4 }
        try await waitUntil("back online on the third attempt") { controller.state == .online }
    }

    @Test("A rejection that arrives while Connecting is not overwritten by the answer that follows")
    func aDropWhileConnectingWins() async throws {
        let session = FakeStreamingSession()
        session.publishDelay = .milliseconds(120)
        let controller = makeController(session: session)
        await controller.startCapture()

        let starting = Task { await controller.startBroadcast() }
        try await waitUntil("connecting") { controller.state == .connecting }

        session.emit(.disconnected(.streamKeyRejected))
        try await waitUntil("reported") { controller.state == .failed(.streamKeyRejected) }

        await starting.value
        try? await Task.sleep(for: .milliseconds(40))

        #expect(controller.state == .failed(.streamKeyRejected))
        #expect(session.publishStopCount >= 1, "nothing was left publishing behind the error")
    }

    @Test("The duration is the length of the broadcast, not of the current connection")
    func durationSurvivesAReconnection() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        try await waitUntil("online") { controller.state == .online }
        try await waitUntil("a second has been counted", timeout: .seconds(3)) {
            controller.elapsedSeconds >= 1
        }

        let attemptsBefore = session.publishStartCount
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("reconnected") { session.publishStartCount > attemptsBefore }
        try await waitUntil("back online") { controller.state == .online }

        #expect(controller.elapsedSeconds >= 1, "the clock restarted at zero after a reconnection")
    }

    @Test("The clock overlay is off until it is asked for, and reaches the session both ways")
    func clockOverlayIsOffUntilAskedFor() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        #expect(controller.isClockOverlayVisible == false)
        #expect(session.overlay == nil)

        await controller.toggleClockOverlay()
        #expect(controller.isClockOverlayVisible)
        #expect(session.overlay?.placement == .topTrailing)
        #expect(session.overlay?.refreshInterval == .seconds(1))

        await controller.toggleClockOverlay()
        #expect(controller.isClockOverlayVisible == false)
        #expect(session.overlay == nil)
    }

    @Test("A shutdown forgets the clock overlay")
    func shutDownForgetsTheClockOverlay() async {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.toggleClockOverlay()
        #expect(controller.isClockOverlayVisible)
        #expect(session.overlay != nil)

        await controller.shutDown()
        #expect(controller.isClockOverlayVisible == false)
        #expect(session.overlay == nil)

        await controller.startCapture()
        #expect(session.overlay == nil)
    }

    // MARK: - The system taking the camera away

    @Test("A call that freezes the picture is said out loud, and the broadcast is not declared dead")
    func captureInterruptionIsShownWhileTheStreamStaysUp() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        try await waitUntil("online") { controller.state == .online }

        session.emit(.captureInterrupted)

        try await waitUntil("the frozen picture is explained") {
            controller.notice == .captureInterrupted
        }
        #expect(
            controller.state == .online,
            "the connection is untouched but the panel says \(controller.state)"
        )
    }

    @Test("The notice goes away by itself when the system hands the camera back")
    func captureResumingClearsTheNotice() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        try await waitUntil("online") { controller.state == .online }

        session.emit(.captureInterrupted)
        try await waitUntil("the frozen picture is explained") {
            controller.notice == .captureInterrupted
        }

        session.emit(.captureResumed)

        try await waitUntil("the notice is gone") { controller.notice == nil }
        #expect(controller.state == .online)
    }

    @Test("A camera coming back does not wipe a notice about something else")
    func captureResumingLeavesAnUnrelatedNoticeAlone() async throws {
        let session = FakeStreamingSession()
        session.switchCameraFailure = .cameraMissing(.front)
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        try await waitUntil("online") { controller.state == .online }
        await controller.switchCamera()
        #expect(controller.notice == .cameraMissing(.front))

        session.emit(.captureResumed)
        // Both events go down the same stream in order, so the drop appearing proves the resume before it was already handled.
        session.emit(.disconnected(.streamKeyRejected))

        try await waitUntil("the event after it was handled") {
            controller.state == .failed(.streamKeyRejected)
        }
        #expect(
            controller.notice == .cameraMissing(.front),
            "a camera coming back cleared a notice it knows nothing about"
        )
    }

    @Test("Backgrounding the app leaves no notice behind about a camera that is now off")
    func shutDownForgetsTheNotice() async {
        let session = FakeStreamingSession()
        session.switchCameraFailure = .cameraMissing(.front)
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.switchCamera()
        #expect(controller.notice == .cameraMissing(.front))

        await controller.shutDown()

        #expect(controller.notice == nil, "a card about a camera that is no longer running")
    }
}
