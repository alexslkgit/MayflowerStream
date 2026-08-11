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
    }

    // MARK: - Capture

    /// Asks for camera and microphone access and opens them. Called from an explicit tap and from
    /// nowhere else — in particular, never from `onAppear`.
    func startCapture() async {
        guard !isCapturing else { return }

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
            cameraFacing = configuration.cameraFacing
            if state.failure != nil { state = .offline }
            listenForEvents()
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
        } catch {
            // A missing camera is a normal thing to run into, not a reason to end the broadcast.
            // Say so and stay on whichever camera is still working.
            state = .failed(error)
        }
    }

    func toggleMicrophone() async {
        guard isCapturing else { return }
        isMicrophoneMuted.toggle()
        await session.setMicrophoneMuted(isMicrophoneMuted)
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
        do {
            try await session.startPublishing(to: endpoint)
            // Going live is confirmed by the server, not by this call returning. `.publishing`
            // is what moves the state to `.online`.
        } catch {
            state = .failed(error)
        }
    }

    func stopBroadcast() async {
        cancelReconnection()
        await session.stopPublishing()
        stopTimer()
        statistics = nil
        state = .offline
    }

    /// The retry offered next to an error message.
    func retry() async {
        guard state.failure != nil else { return }
        state = .offline
        if isCapturing {
            await startBroadcast()
        } else {
            await startCapture()
        }
    }

    /// Closes everything. Used when the screen goes away and when the app is backgrounded.
    func shutDown() async {
        cancelReconnection()
        eventTask?.cancel()
        eventTask = nil
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

    private func listenForEvents() {
        guard eventTask == nil else { return }
        // Exactly one reader, for the lifetime of the session. See StreamingSession.events.
        eventTask = Task { [weak self, session] in
            for await event in session.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: StreamingEvent) async {
        switch event {
        case .publishing:
            cancelReconnection()
            if startedAt == nil { startedAt = Date() }
            state = .online
            startTimer()
            await refreshStatistics()

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

    private func beginReconnecting() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...reconnectPolicy.maximumAttempts {
                state = .reconnecting(attempt: attempt)
                try? await Task.sleep(for: reconnectPolicy.delay(attempt))
                if Task.isCancelled { return }

                do {
                    try await session.startPublishing(to: endpoint)
                    // Success here only means the request was accepted. `.publishing` ends the
                    // reconnection for real, and it is what cancels this task.
                    return
                } catch {
                    if Task.isCancelled { return }
                    continue
                }
            }
            stopTimer()
            statistics = nil
            state = .failed(.reconnectionGaveUp(attempts: reconnectPolicy.maximumAttempts))
            reconnectTask = nil
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
    /// `01:23` up to an hour, `1:02:03` past it.
    var formattedDuration: String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
