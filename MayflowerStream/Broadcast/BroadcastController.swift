//
//  BroadcastController.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation

@MainActor
@Observable
final class BroadcastController {

    // MARK: - What the screen reads

    private(set) var state: BroadcastState = .offline
    private(set) var isCapturing = false
    private(set) var isMicrophoneMuted = false
    private(set) var isClockOverlayVisible = false
    var cameraFacing: CameraFacing { configuration.cameraFacing }
    private(set) var elapsedSeconds: Int = 0
    /// Whole seconds left of the current backoff wait; nil while an attempt is actually in flight.
    private(set) var secondsUntilNextAttempt: Int?
    private(set) var statistics: StreamStatistics?
    /// Local capture failures only; `state` covers the remote stream and is never overwritten here.
    private(set) var notice: BroadcastFailure?

    // MARK: - Collaborators

    private let session: any StreamingSession
    private let permissions: any MediaPermissions
    private let endpoint: StreamEndpoint
    private let reconnectPolicy: ReconnectPolicy
    private let connectivity: any ConnectivityMonitor
    private let countdownTick: Duration
    private let pathSettleDelay: Duration
    private var configuration: BroadcastConfiguration

    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectivityTask: Task<Void, Never>?
    /// `stopBroadcast()` goes offline before this runs; every caller awaits it so two handshakes
    /// never race on one RTMP connection.
    private var teardownTask: Task<Void, Never>?
    private var backoffWait: Task<Void, Never>?
    /// True once the connectivity monitor sees the path return during this reconnection; skips the
    /// remaining backoff. Cleared on the next loss, so a flapping path must return again to skip.
    private var isPathBackAfterLoss = false
    /// One settle is owed per return of the path; cleared as it is taken, so the skip stays a skip.
    private var isPathSettleOwed = false
    private var startedAt: Date?
    private var isStartingCapture = false
    private var isTogglingMicrophone = false
    private var isSwitchingCamera = false
    /// Bumped on every stop; anything in flight from an older generation is discarded on completion.
    private var broadcastGeneration = 0

    init(
        endpoint: StreamEndpoint,
        session: any StreamingSession,
        permissions: any MediaPermissions = SystemMediaPermissions(),
        configuration: BroadcastConfiguration = .default,
        reconnectPolicy: ReconnectPolicy = .default,
        connectivity: any ConnectivityMonitor = NetworkPathMonitor(),
        countdownTick: Duration = .seconds(1),
        pathSettleDelay: Duration = .milliseconds(750)
    ) {
        self.endpoint = endpoint
        self.session = session
        self.permissions = permissions
        self.configuration = configuration
        self.reconnectPolicy = reconnectPolicy
        self.connectivity = connectivity
        self.countdownTick = countdownTick
        self.pathSettleDelay = pathSettleDelay
        listenForEvents()
    }

    // MARK: - Capture

    /// Called from an explicit tap only, never from `onAppear`.
    func startCapture() async {
        guard !isCapturing, !isStartingCapture else { return }
        isStartingCapture = true
        defer { isStartingCapture = false }
        // Captured before the first await so a `shutDown()` landing mid-call is detected below.
        let generation = broadcastGeneration

        if let failure = await permissions.requestAccess(to: .camera).failure(for: .camera) {
            if generation == broadcastGeneration { state = .failed(failure) }
            return
        }
        if let failure = await permissions.requestAccess(to: .microphone).failure(for: .microphone) {
            if generation == broadcastGeneration { state = .failed(failure) }
            return
        }

        do {
            try await session.startCapture(configuration)
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
            notice = error
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func toggleClockOverlay() async {
        isClockOverlayVisible.toggle()
        await session.setOverlay(isClockOverlayVisible ? ClockOverlay() : nil)
    }

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
        await waitForTeardown()
        guard generation == broadcastGeneration else { return }
        do {
            try await session.startPublishing(to: endpoint)
            // `.publishing` can arrive first and set `.online` before this returns; both are this
            // broadcast succeeding, and `goOnline()` is idempotent.
            guard generation == broadcastGeneration, state == .connecting || state == .online else {
                await session.stopPublishing()
                return
            }
            await goOnline()
        } catch {
            guard generation == broadcastGeneration else { return }
            state = .failed(error)
        }
    }

    /// Every write happens before the first await; the goodbye itself is not something the screen
    /// waits for.
    func stopBroadcast() async {
        broadcastGeneration += 1
        cancelReconnection()
        stopTimer()
        statistics = nil
        state = .offline

        beginTeardown()
        await waitForTeardown()
    }

    private func beginTeardown() {
        guard teardownTask == nil else { return }
        teardownTask = Task { [weak self] in
            guard let self else { return }
            await session.stopPublishing()
            teardownTask = nil
        }
    }

    private func waitForTeardown() async {
        guard let teardownTask else { return }
        await teardownTask.value
    }

    func retry() async {
        guard let failure = state.failure else { return }
        state = .offline
        if failure.isDeviceProblem {
            await startCapture()
        } else {
            await startBroadcast()
        }
    }

    /// The event reader is left running: cancelling an `AsyncStream` reader ends it for good, and a
    /// reader started for the next broadcast would receive nothing.
    func shutDown() async {
        broadcastGeneration += 1
        cancelReconnection()
        stopTimer()
        await waitForTeardown()
        await session.stopPublishing()
        await session.stopCapture()
        isCapturing = false
        statistics = nil
        state = .offline
        notice = nil
        isClockOverlayVisible = false
        await session.setOverlay(nil)
    }

    func refreshStatistics() async {
        let generation = broadcastGeneration
        let measured = await session.currentStatistics()
        guard generation == broadcastGeneration else { return }
        statistics = measured
    }

    // MARK: - Events

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
            guard state.isLive || state.isBusy else { return }
            await goOnline()

        case .disconnected(let failure):
            guard state.isLive || state.isBusy else { return }
            // A refusal reported while a reconnection is already running is the network, not the
            // key: the key was accepted when this broadcast went Online. A revoked one is refused
            // again on the next manual start, where it is reported as itself.
            if failure.isWorthRetrying || reconnectTask != nil {
                beginReconnecting()
            } else {
                stopTimer()
                statistics = nil
                state = .failed(failure)
            }

        case .captureInterrupted:
            notice = .captureInterrupted

        case .captureResumed:
            if notice == .captureInterrupted { notice = nil }
        }
    }

    // MARK: - Reconnection

    /// The only place `state` becomes `.online`; idempotent since a successful publish and the
    /// server's `.publishing` event can both call it for the same broadcast.
    private func goOnline() async {
        cancelReconnection()
        if startedAt == nil { startedAt = Date() }
        state = .online
        startTimer()
        await refreshStatistics()
    }

    private func beginReconnecting() {
        guard reconnectTask == nil else { return }
        startWatchingConnectivity()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let generation = broadcastGeneration
            for attempt in 1...reconnectPolicy.maximumAttempts {
                state = .reconnecting(attempt: attempt)
                await waitBeforeAttempt(reconnectPolicy.delay(attempt))
                if Task.isCancelled || generation != broadcastGeneration { return }

                do {
                    try await session.startPublishing(to: endpoint)
                    // Decided from generation/state, not `Task.isCancelled`: the `.publishing` event
                    // routinely fires first and its `goOnline()` cancels this task on success.
                    guard generation == broadcastGeneration else {
                        await session.stopPublishing()
                        return
                    }
                    if state == .online { return }
                    guard state == .reconnecting(attempt: attempt) else {
                        await session.stopPublishing()
                        reconnectTask = nil
                        stopWatchingConnectivity()
                        return
                    }
                    await goOnline()
                    return
                } catch {
                    if Task.isCancelled || generation != broadcastGeneration { return }
                    continue
                }
            }
            reconnectTask = nil
            stopWatchingConnectivity()
            stopTimer()
            statistics = nil
            state = .failed(.reconnectionGaveUp(attempts: reconnectPolicy.maximumAttempts))
        }
    }

    private func waitBeforeAttempt(_ delay: Duration) async {
        if isPathBackAfterLoss {
            await settleAfterRestore()
            return
        }
        let wait = Task { () async -> Void in
            try? await Task.sleep(for: delay)
        }
        backoffWait = wait
        startCountdown(over: delay)
        await withTaskCancellationHandler {
            await wait.value
        } onCancel: {
            wait.cancel()
        }
        stopCountdown()
        backoffWait = nil
        // The wait above may have been cut short by the same return of the path.
        await settleAfterRestore()
    }

    /// A path the system reports as satisfied is not yet one that carries a connection — Wi-Fi is
    /// still associating, DNS is not answering — and an attempt fired on that edge fails in under a
    /// second for a reason that is not the server's. Bounded and taken once per return of the path,
    /// so the backoff the skip removed does not come back.
    private func settleAfterRestore() async {
        guard isPathSettleOwed else { return }
        isPathSettleOwed = false
        try? await Task.sleep(for: pathSettleDelay)
    }

    /// Counts alongside the wait instead of driving it, so a skipped backoff is still the one
    /// cancellation the loop knows about. Sub-second waits show nothing rather than flashing "0s".
    private func startCountdown(over delay: Duration) {
        let seconds = Int(delay.components.seconds)
        guard seconds > 0 else { return }
        secondsUntilNextAttempt = seconds
        countdownTask = Task { [weak self] in
            while let self, let remaining = secondsUntilNextAttempt, remaining > 1 {
                try? await Task.sleep(for: countdownTick)
                guard !Task.isCancelled else { return }
                secondsUntilNextAttempt = remaining - 1
            }
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        secondsUntilNextAttempt = nil
    }

    /// Runs only for the lifetime of a reconnection. A satisfied update counts as "back" only after
    /// an unsatisfied one was seen in this reconnection, and a fresh loss re-arms that edge.
    private func startWatchingConnectivity() {
        guard connectivityTask == nil else { return }
        connectivityTask = Task { [weak self] in
            guard let updates = await self?.connectivity.updates() else { return }
            var pathWasLost = false
            for await isSatisfied in updates {
                guard let self else { return }
                guard isSatisfied else {
                    pathWasLost = true
                    isPathBackAfterLoss = false
                    isPathSettleOwed = false
                    continue
                }
                guard pathWasLost else { continue }
                pathWasLost = false
                isPathBackAfterLoss = true
                isPathSettleOwed = true
                backoffWait?.cancel()
            }
        }
    }

    private func stopWatchingConnectivity() {
        connectivityTask?.cancel()
        connectivityTask = nil
        isPathBackAfterLoss = false
        isPathSettleOwed = false
    }

    private func cancelReconnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        stopCountdown()
        stopWatchingConnectivity()
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

    static func formatDuration(seconds elapsed: Int) -> String {
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
