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

    private func makeController(
        session: FakeStreamingSession,
        permissions: StubMediaPermissions = StubMediaPermissions(),
        configuration: BroadcastConfiguration = .default,
        reconnect: ReconnectPolicy = instantReconnect
    ) -> BroadcastController {
        BroadcastController(
            endpoint: Self.endpoint,
            session: session,
            permissions: permissions,
            configuration: configuration,
            reconnectPolicy: reconnect
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

    // MARK: - Going live

    @Test("Going live waits for the server, not for the tap")
    func onlineOnlyWhenTheServerConfirms() async throws {
        let session = FakeStreamingSession()
        // The server takes its time answering, which is the whole point: until it does, the user
        // is told Connecting and nothing else.
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

        // The `.publishing` event lands while `startPublishing` is still in flight, so the state
        // is already `.online` when the call returns. That must read as success, not as someone
        // having cancelled the broadcast.
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

    // MARK: - Losing the connection

    @Test("A dropped connection reconnects on its own and comes back online")
    func reconnectsAfterADrop() async throws {
        let session = FakeStreamingSession()
        // A real pause before the first attempt, so that "Reconnecting" is on screen long enough
        // for the test to see it rather than being raced past.
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

        // The reconnection attempt now hangs inside `startPublishing`, which is the window the
        // server's confirmation arrives in on a real connection.
        session.publishDelay = .milliseconds(80)
        let attemptsBefore = session.publishStartCount
        session.emit(.disconnected(.connectionLost))
        try await waitUntil("the reconnection attempt is in flight") {
            session.publishStartCount > attemptsBefore
        }

        // The `.publishing` event lands first and puts the broadcast back on air, which cancels
        // the reconnection task. That cancellation is the reconnection succeeding, so the attempt
        // returning afterwards must not take the connection it just re-established down again.
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

        // Giving up is the one failure the app writes about itself, after its own bookkeeping has
        // been unwound, so the button under it has to still work.
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

        // The publish ends but the socket stays up. Unless the session closes it, every
        // reconnection attempt is refused before it reaches the server.
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
        // One publish that works, then nothing does: this reconnection is going to run out of
        // attempts, which is the ending that has to be checked against a user who stopped.
        session.publishFailures = [nil, .serverUnreachable, .serverUnreachable, .serverUnreachable]
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        // A slow last attempt, so the stop lands in the window between it failing and the
        // reconnection admitting defeat.
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
        // A real delay between attempts here, unlike the other tests: this one needs the controller
        // to still be mid-reconnection when stop is called, and with no delay the whole sequence
        // would be over before the test could look at it.
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
        // A slow server, so that going Online can only have come from the event and not from the
        // request returning. That is the half that goes silent when the stream has been torn down:
        // the app still publishes, and simply stops hearing anything the server says.
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
        // The camera is still opening when the app goes to the background, which is the window the
        // whole bug lives in: the session takes down what it built and returns without throwing,
        // so the only thing that can tell this start its result is unwanted is the generation.
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
        #expect(session.overlay?.placement == .topCenter)
        #expect(session.overlay?.refreshInterval == .seconds(1))

        await controller.toggleClockOverlay()
        #expect(controller.isClockOverlayVisible == false)
        #expect(session.overlay == nil)
    }
}
