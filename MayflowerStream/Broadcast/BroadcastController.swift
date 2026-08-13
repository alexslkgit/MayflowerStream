import Foundation

/// Screen 2's brain: it owns the broadcast state machine, the duration, and the translation of
/// everything that goes wrong into something the screen can say.
///
/// Two things are kept strictly apart here, because the task is explicit that confusing them is a
/// failure. `isCapturing` is about the local camera. `state` is about the remote stream. A running
/// preview with a dead connection is `.offline`, and the panel says Offline.
@MainActor
@Observable
final class BroadcastController {

    // MARK: - What the screen reads

    private(set) var state: BroadcastState = .offline
    /// True once the camera and microphone are open. Nothing opens them but `startCapture()`.
    private(set) var isCapturing = false
    private(set) var isMicrophoneMuted = false
    private(set) var cameraFacing: CameraFacing
    /// Seconds since the broadcast first went live. Keeps counting through a reconnection, because
    /// it is the length of the broadcast, not the length of the current TCP connection.
    private(set) var elapsedSeconds: Int = 0
    private(set) var statistics: StreamStatistics?
    /// Something went wrong that has nothing to do with whether the stream is live — a camera that
    /// refused to switch, say. It gets its own card on screen and leaves `state` alone: writing it
    /// into `state` would tell a user whose broadcast is still going out that it had stopped.
    private(set) var notice: BroadcastFailure?

    // MARK: - Collaborators

    private let session: any StreamingSession
    private let permissions: any MediaPermissions
    private let endpoint: StreamEndpoint
    private let reconnectPolicy: ReconnectPolicy
    private var configuration: BroadcastConfiguration

    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var startedAt: Date?
    /// Set before the first await in `startCapture()`, so that a second tap arriving while the
    /// camera is still opening is turned away. `isCapturing` cannot do that job: it only becomes
    /// true after the awaits, which is exactly the window a double tap falls into.
    private var isStartingCapture = false
    private var isTogglingMicrophone = false
    /// Bumped every time the user stops. Anything that was in flight across that moment belongs to
    /// an older broadcast and its result is discarded, so a publish the user has already cancelled
    /// cannot put them back on air.
    private var broadcastGeneration = 0

    init(
        endpoint: StreamEndpoint,
        session: any StreamingSession,
        permissions: any MediaPermissions = SystemMediaPermissions(),
        configuration: BroadcastConfiguration = .default,
        reconnectPolicy: ReconnectPolicy = .default
    ) {
        self.endpoint = endpoint
        self.session = session
        self.permissions = permissions
        self.configuration = configuration
        self.reconnectPolicy = reconnectPolicy
        self.cameraFacing = configuration.cameraFacing
        listenForEvents()
    }

    // MARK: - Capture

    /// Asks for camera and microphone access and opens them. Called from an explicit tap and from
    /// nowhere else — in particular, never from `onAppear`.
    func startCapture() async {
        guard !isCapturing, !isStartingCapture else { return }
        isStartingCapture = true
        defer { isStartingCapture = false }

        guard await permissions.requestAccess(to: .camera) == .granted else {
            state = .failed(.cameraAccessDenied)
            return
        }
        // Audio is not optional: the broadcast is required to carry an AAC track, so a refusal
        // here has to stop the preview rather than quietly produce a silent stream later.
        guard await permissions.requestAccess(to: .microphone) == .granted else {
            state = .failed(.microphoneAccessDenied)
            return
        }

        do {
            try await session.startCapture(configuration)
            isCapturing = true
            isMicrophoneMuted = false
            notice = nil
            cameraFacing = configuration.cameraFacing
            if state.failure != nil { state = .offline }
        } catch {
            state = .failed(error)
        }
    }

    func switchCamera() async {
        guard isCapturing else { return }
        let target: CameraFacing = cameraFacing == .back ? .front : .back
        do {
            try await session.switchCamera(to: target)
            cameraFacing = target
            configuration.cameraFacing = target
            notice = nil
        } catch {
            // A missing camera is a normal thing to run into, not a reason to end the broadcast.
            // Say so, stay on whichever camera is still working, and leave the broadcast state
            // exactly as it was — it is still true.
            notice = error
        }
    }

    func dismissNotice() {
        notice = nil
    }

    /// The flag the icon is drawn from is set from what the session reports it applied, never from
    /// what was asked for — and a second tap arriving mid-flight is turned away rather than
    /// computed from a value that is about to change.
    func toggleMicrophone() async {
        guard isCapturing, !isTogglingMicrophone else { return }
        isTogglingMicrophone = true
        defer { isTogglingMicrophone = false }
        isMicrophoneMuted = await session.setMicrophoneMuted(!isMicrophoneMuted)
    }

    // MARK: - Broadcast

    func startBroadcast() async {
        guard isCapturing else { return }
        guard !state.isLive, !state.isBusy else { return }

        do {
            try configuration.validate()
        } catch {
            state = .failed(error)
            return
        }

        state = .connecting
        let generation = broadcastGeneration
        do {
            try await session.startPublishing(to: endpoint)
            // This call returns only once the server has answered "publish started", so the
            // return *is* the confirmation. The `.publishing` event says the same thing a moment
            // later and `goOnline()` is idempotent, so whichever arrives first is enough.
            guard generation == broadcastGeneration, state == .connecting else {
                // Either the user stopped while this was in flight, or something else has already
                // decided what the state is — a drop reported before the server answered, say. The
                // server is publishing a broadcast nobody is waiting for, so take it down again.
                await session.stopPublishing()
                return
            }
            await goOnline()
        } catch {
            guard generation == broadcastGeneration else { return }
            state = .failed(error)
        }
    }

    func stopBroadcast() async {
        broadcastGeneration += 1
        cancelReconnection()
        await session.stopPublishing()
        stopTimer()
        statistics = nil
        state = .offline
    }

    /// The retry offered next to an error message.
    ///
    /// What failed decides what is tried again. Whether the camera happens to be running does not:
    /// branching on that is how "Try again" under a camera error ends up putting the user on air.
    func retry() async {
        guard let failure = state.failure else { return }
        state = .offline
        if failure.isDeviceProblem {
            await startCapture()
        } else {
            await startBroadcast()
        }
    }

    /// Closes everything. Used when the screen goes away and when the app is backgrounded.
    ///
    /// The event reader is deliberately left running: cancelling the consumer of an `AsyncStream`
    /// finishes that stream for good, and a reader started afterwards would receive nothing — the
    /// next broadcast would publish frames while the screen still said Connecting.
    func shutDown() async {
        broadcastGeneration += 1
        cancelReconnection()
        stopTimer()
        await session.stopPublishing()
        await session.stopCapture()
        isCapturing = false
        statistics = nil
        state = .offline
    }

    func refreshStatistics() async {
        statistics = await session.currentStatistics()
    }

    // MARK: - Events

    /// Started once, from `init`, and never stopped. See `StreamingSession.events` for why there
    /// can only ever be one reader, and `shutDown()` for why it outlives a background cycle.
    /// The stream itself is captured rather than the session, so this task holds nothing alive.
    private func listenForEvents() {
        guard eventTask == nil else { return }
        let events = session.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: StreamingEvent) async {
        switch event {
        case .publishing:
            // Only meaningful while the app is trying to be, or believes it is, on air. After an
            // explicit stop this is the server confirming a broadcast the user already cancelled.
            guard state.isLive || state.isBusy else { return }
            await goOnline()

        case .disconnected(let failure):
            guard state.isLive || state.isBusy else { return }
            if failure.isWorthRetrying {
                beginReconnecting()
            } else {
                stopTimer()
                statistics = nil
                state = .failed(failure)
            }
        }
    }

    // MARK: - Reconnection

    /// The one place `state` becomes `.online`, reached both from a successful publish and from
    /// the server's `.publishing` event. Idempotent, because both can happen for the same
    /// broadcast, and because a reconnection ends the same way an initial connection does.
    private func goOnline() async {
        cancelReconnection()
        if startedAt == nil { startedAt = Date() }
        state = .online
        startTimer()
        await refreshStatistics()
    }

    private func beginReconnecting() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let generation = broadcastGeneration
            for attempt in 1...reconnectPolicy.maximumAttempts {
                state = .reconnecting(attempt: attempt)
                try? await Task.sleep(for: reconnectPolicy.delay(attempt))
                if Task.isCancelled || generation != broadcastGeneration { return }

                do {
                    try await session.startPublishing(to: endpoint)
                    if Task.isCancelled || generation != broadcastGeneration {
                        await session.stopPublishing()
                        return
                    }
                    // `goOnline()` clears `reconnectTask`, and that is what lets the *next* drop
                    // start its own reconnection. Leaving it set is what turns one lost connection
                    // into a permanent "Reconnecting (1)".
                    await goOnline()
                    return
                } catch {
                    if Task.isCancelled || generation != broadcastGeneration { return }
                    continue
                }
            }
            reconnectTask = nil
            stopTimer()
            statistics = nil
            state = .failed(.reconnectionGaveUp(attempts: reconnectPolicy.maximumAttempts))
        }
    }

    private func cancelReconnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Duration

    private func startTimer() {
        guard tickTask == nil else { return }
        updateElapsed()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                updateElapsed()
            }
        }
    }

    private func stopTimer() {
        tickTask?.cancel()
        tickTask = nil
        startedAt = nil
        elapsedSeconds = 0
    }

    private func updateElapsed() {
        guard let startedAt else { return }
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
    }
}

extension BroadcastController {
    var formattedDuration: String {
        Self.formatDuration(seconds: elapsedSeconds)
    }

    /// `01:23` up to an hour, `1:02:03` past it. A broadcaster reads the minutes, so they keep
    /// their two digits and the hours only appear once there are any.
    static func formatDuration(seconds elapsed: Int) -> String {
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
