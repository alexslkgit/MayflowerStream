//
//  BroadcastController.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

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
    private(set) var isClockOverlayVisible = false
    /// Read out of the configuration rather than kept beside it: a second copy of the same fact is
    /// one forgotten write site away from disagreeing with the first, and the disagreement shows up
    /// as a button that switches to the camera the user is already on. `configuration` is stored on
    /// this `@Observable` class, so the screen still sees this change when the camera is switched.
    var cameraFacing: CameraFacing { configuration.cameraFacing }
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
    /// Same job for the camera button. Two switches in flight at once race each other over one
    /// capture session, and the second one reads a `cameraFacing` the first is about to change —
    /// so a fast double tap decides to switch to the camera it is already switching to.
    private var isSwitchingCamera = false
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
        listenForEvents()
    }

    // MARK: - Capture

    /// Called from an explicit tap and from nowhere else — in particular, never from `onAppear`.
    func startCapture() async {
        guard !isCapturing, !isStartingCapture else { return }
        isStartingCapture = true
        defer { isStartingCapture = false }
        // Read before the first await, the same discipline `startBroadcast()` uses one level down.
        // `shutDown()` and `stopBroadcast()` both move it, and a `shutDown()` landing at any of the
        // awaits below has already closed the camera this call is opening: the session tears down
        // its own half and returns normally, so nothing here throws and this counter is the only
        // thing that says the result is no longer wanted. Every write below is skipped once it has
        // moved — the permission failures included, because a user who left the screen is owed the
        // Offline the shutdown left behind rather than an error card about a camera nobody is
        // looking at any more.
        let generation = broadcastGeneration

        guard await permissions.requestAccess(to: .camera) == .granted else {
            if generation == broadcastGeneration { state = .failed(.cameraAccessDenied) }
            return
        }
        // Audio is not optional: the broadcast is required to carry an AAC track, so a refusal
        // here has to stop the preview rather than quietly produce a silent stream later.
        guard await permissions.requestAccess(to: .microphone) == .granted else {
            if generation == broadcastGeneration { state = .failed(.microphoneAccessDenied) }
            return
        }

        do {
            try await session.startCapture(configuration)
            // Nothing is left running to take down here — the session did that itself — so what is
            // left to get wrong is `isCapturing`: setting it now draws a preview and a full set of
            // controls over a pipeline that no longer exists.
            guard generation == broadcastGeneration else { return }
            isCapturing = true
            isMicrophoneMuted = false
            notice = nil
            if state.failure != nil { state = .offline }
        } catch {
            guard generation == broadcastGeneration else { return }
            state = .failed(error)
        }
    }

    func switchCamera() async {
        guard isCapturing, !isSwitchingCamera else { return }
        isSwitchingCamera = true
        defer { isSwitchingCamera = false }
        let target: CameraFacing = cameraFacing == .back ? .front : .back
        do {
            try await session.switchCamera(to: target)
            configuration.cameraFacing = target
            notice = nil
        } catch {
            // A missing camera is a normal thing to run into, not a reason to end the broadcast.
            // The broadcast state is left exactly as it was — it is still true.
            notice = error
        }
    }

    func dismissNotice() {
        notice = nil
    }

    /// Burns the time of day into the picture, or takes it back off. Off when the screen opens.
    func toggleClockOverlay() async {
        isClockOverlayVisible.toggle()
        await session.setOverlay(isClockOverlayVisible ? ClockOverlay() : nil)
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
            // return *is* the confirmation. The `.publishing` event says the same thing and can
            // arrive first, setting `.online` before this line runs — that is still this broadcast
            // succeeding, not somebody else's decision, and `goOnline()` is idempotent.
            guard generation == broadcastGeneration, state == .connecting || state == .online else {
                // Either the user stopped while this was in flight, or a drop reported before the
                // server answered has already decided the state. The server is publishing a
                // broadcast nobody is waiting for, so take it down again.
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
                // Cancellation may be read here only because this check can do nothing but return:
                // nothing has been published yet, so there is nothing that could be left behind.
                if Task.isCancelled || generation != broadcastGeneration { return }

                do {
                    try await session.startPublishing(to: endpoint)
                    // What happens now is decided from the generation and the state, never from
                    // `Task.isCancelled`. The server's `.publishing` event routinely arrives before
                    // this call returns, and the `goOnline()` it triggers cancels this very task —
                    // so cancellation here usually means the reconnection *worked*, and stopping on
                    // it would tear down the connection that was just re-established. A user who
                    // stopped is visible in the generation, which is what `stopBroadcast()` and
                    // `shutDown()` bump.
                    guard generation == broadcastGeneration else {
                        // Stopped while this was in flight. The server is publishing a broadcast
                        // nobody is waiting for, so take it down again.
                        await session.stopPublishing()
                        return
                    }
                    // The event won the race and `goOnline()` has already put this broadcast back
                    // on air. Nothing left to do, and nothing to take down.
                    if state == .online { return }
                    guard state == .reconnecting(attempt: attempt) else {
                        // A drop not worth retrying was reported while this was in flight and has
                        // already ended the broadcast. What the server just accepted belongs to
                        // nobody, so take it down rather than leave it publishing behind an error.
                        await session.stopPublishing()
                        reconnectTask = nil
                        return
                    }
                    // `goOnline()` clears `reconnectTask`, and that is what lets the *next* drop
                    // start its own reconnection. Leaving it set is what turns one lost connection
                    // into a permanent "Reconnecting (1)".
                    await goOnline()
                    return
                } catch {
                    // Return-only as well, so cancellation is safe to read here: the attempt threw,
                    // and a `startPublishing` that throws leaves nothing open behind it.
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
