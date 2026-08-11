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

    @Test("Going live waits for the server, not for the request to return")
    func onlineOnlyWhenTheServerConfirms() async throws {
        let session = FakeStreamingSession()
        let controller = makeController(session: session)
        await controller.startCapture()

        await controller.startBroadcast()
        #expect(controller.state == .connecting, "publishing was requested but not yet confirmed")

        session.emit(.publishing)
        try await waitUntil("state becomes online") { controller.state == .online }

        #expect(controller.state.isLive)
        #expect(controller.statistics != nil)
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
        let controller = makeController(session: session)
        await controller.startCapture()
        await controller.startBroadcast()
        session.emit(.publishing)
        try await waitUntil("online") { controller.state == .online }

        session.emit(.disconnected(.connectionLost))
        try await waitUntil("reconnection started") {
            if case .reconnecting = controller.state { return true }
            return false
        }

        session.emit(.publishing)
        try await waitUntil("back online") { controller.state == .online }

        #expect(session.publishStartCount >= 2)
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
        #expect(controller.state == .failed(.cameraMissing(.front)))
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
    }
}

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

@Suite("Failure messages")
struct BroadcastFailureTests {

    private static let all: [BroadcastFailure] = [
        .cameraAccessDenied, .microphoneAccessDenied, .cameraMissing(.front), .cameraMissing(.back),
        .cameraUnavailable, .unsupportedConfiguration(reason: "The frame rate is too high."),
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

    @Test("The unexpected case keeps its detail for a log but never shows it")
    func unexpectedKeepsDetailOutOfSight() {
        let failure = BroadcastFailure.unexpected(detail: "NetConnection.Connect.Whatever")
        #expect(!failure.message.contains("NetConnection"))
        #expect(failure.diagnosticDescription.contains("NetConnection"))
    }
}
