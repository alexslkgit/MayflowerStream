//
//  StreamView.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import HaishinKit
import SwiftUI

private enum Strings {
    static let navigationTitle = "Broadcast"
    static func nextAttempt(inSeconds seconds: Int) -> String { "Next attempt in \(seconds)s" }
    static let cameraOffMessage = "The camera is off."
    static let turnOnCamera = "Turn on the camera"
    static let restoringCamera = "Bringing the camera back…"
    static let resumingBroadcast = "Picking the broadcast back up…"
    static let muteMicrophone = "Mute microphone"
    static let unmuteMicrophone = "Unmute microphone"
    static let showClockOverlay = "Show the clock overlay"
    static let hideClockOverlay = "Hide the clock overlay"
    static let switchCamera = "Switch camera"
    static let startBroadcast = "Start broadcast"
    static let stopBroadcast = "Stop broadcast"
    static let ok = "OK"
    static let openSettings = "Open Settings"
    static let editStreamKey = "Edit stream key"
    static let tryAgain = "Try again"
}

struct StreamView: View {
    @State private var screen: StreamScreen
    @State private var isShowingParameters = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    init(endpoint: StreamEndpoint) {
        _screen = State(initialValue: StreamScreen(endpoint: endpoint))
    }

    private var controller: BroadcastController { screen.controller }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch Self.backdrop(
                isRestoring: controller.isRestoring,
                isCapturing: controller.isCapturing,
                state: controller.state
            ) {
            case .preview:
                // Excludes the top edge only, so the preview never draws under the status bar.
                CameraPreview(session: screen.session)
                    .equatable()
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
            case .restoringCamera:
                restorePlaceholder(Strings.restoringCamera)
            case .resumingBroadcast:
                restorePlaceholder(Strings.resumingBroadcast)
            case .cameraOff:
                idlePlaceholder
            }

            VStack {
                statusPanel
                if let seconds = controller.secondsUntilNextAttempt {
                    countdownHUD(seconds)
                }
                if controller.state.isLive,
                   let statistics = controller.statistics,
                   let summary = statistics.onAirSummary {
                    onAirHUD(summary, spokenAs: statistics.onAirAccessibilityLabel)
                }
                Spacer()
                if let notice = controller.notice {
                    noticeCard(notice)
                }
                if let failure = controller.state.failure {
                    failureCard(failure)
                }
                if controller.isCapturing {
                    controls
                }
            }
            .padding()
        }
        .navigationTitle(Strings.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingParameters) {
            StreamParametersSheet(
                state: controller.state,
                duration: controller.formattedDuration,
                statistics: controller.statistics
            )
        }
        .task(id: isShowingParameters) {
            while isShowingParameters, !Task.isCancelled {
                await controller.refreshStatistics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: controller.state.isLive) {
            while controller.state.isLive, !Task.isCancelled {
                await controller.refreshStatistics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: controller.isCapturing) { _, isCapturing in
            UIApplication.shared.isIdleTimerDisabled = isCapturing
        }
        .onChange(of: scenePhase) { _, phase in
            if Self.shouldShutDown(on: phase) {
                UIApplication.shared.isIdleTimerDisabled = false
                Task { await controller.suspendForBackground() }
            } else if Self.shouldRestorePreview(on: phase) {
                Task { await controller.restoreAfterForeground() }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await controller.shutDown() }
        }
    }

    // `.inactive` also fires while the system permission alert is on screen; only `.background`
    // should tear the camera down.
    nonisolated static func shouldShutDown(on phase: ScenePhase) -> Bool {
        phase == .background
    }

    /// Asking is free: the controller only owes a restore after a real `.background`, so returning
    /// from a permission alert or Control Centre finds nothing to do.
    nonisolated static func shouldRestorePreview(on phase: ScenePhase) -> Bool {
        phase == .active
    }

    enum Backdrop: Equatable {
        case preview
        case restoringCamera
        case resumingBroadcast
        case cameraOff
    }

    /// Pure for the same reason as `cardActions(for:)`. A restore releases the camera before it starts
    /// it again, so the plain reading of `isCapturing` offers *Turn on the camera* for something the
    /// app is already doing — a button whose only effect is to fight the restore.
    nonisolated static func backdrop(
        isRestoring: Bool,
        isCapturing: Bool,
        state: BroadcastState
    ) -> Backdrop {
        guard isRestoring else { return isCapturing ? .preview : .cameraOff }
        if case .reconnecting = state { return .resumingBroadcast }
        return .restoringCamera
    }

    // MARK: - Pieces

    private var statusPanel: some View {
        StreamStatusPanel(
            state: controller.state,
            duration: controller.formattedDuration,
            onTap: controller.state.isLive ? { isShowingParameters = true } : nil
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countdownHUD(_ seconds: Int) -> some View {
        Text(Strings.nextAttempt(inSeconds: seconds))
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func onAirHUD(_ summary: String, spokenAs spoken: String?) -> some View {
        Text(summary)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(spoken ?? summary)
    }

    private var idlePlaceholder: some View {
        VStack(spacing: 20) {
            Image(systemName: "video.circle")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.6))
            Text(Strings.cameraOffMessage)
                .foregroundStyle(.white.opacity(0.8))
            Button(Strings.turnOnCamera) {
                Task { await controller.startCapture() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // No camera imagery and nothing to tap: the last frame is stale and every control here belongs
    // to a pipeline that is being rebuilt.
    private func restorePlaceholder(_ message: String) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(message)
                .foregroundStyle(.white.opacity(0.8))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }

    // Layered in its own ZStack so the record button stays centred on the screen rather than
    // between the side controls, which are not the same width on each side.
    private var controls: some View {
        ZStack {
            HStack {
                HStack(spacing: 10) {
                    circleButton(
                        systemImage: controller.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                        label: controller.isMicrophoneMuted ? Strings.unmuteMicrophone : Strings.muteMicrophone,
                        tint: controller.isMicrophoneMuted ? .red : .white
                    ) {
                        Task { await controller.toggleMicrophone() }
                    }

                    // What is drawn here is drawn into the outgoing frames as well.
                    circleButton(
                        systemImage: "clock.fill",
                        label: controller.isClockOverlayVisible ? Strings.hideClockOverlay : Strings.showClockOverlay,
                        tint: controller.isClockOverlayVisible ? .yellow : .white
                    ) {
                        Task { await controller.toggleClockOverlay() }
                    }
                }

                Spacer()

                circleButton(
                    systemImage: "arrow.triangle.2.circlepath.camera.fill",
                    label: Strings.switchCamera,
                    tint: .white
                ) {
                    Task { await controller.switchCamera() }
                }
            }

            // Last, so it stays on top of the row and keeps its full tap target.
            broadcastButton
        }
        .padding(.horizontal, 8)
    }

    private var broadcastButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task {
                if controller.state.isLive || controller.state.isBusy {
                    await controller.stopBroadcast()
                } else {
                    await controller.startBroadcast()
                }
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: isStopShape ? 6 : 30)
                    .fill(.red)
                    .frame(width: isStopShape ? 30 : 60, height: isStopShape ? 30 : 60)
                if controller.state.isBusy {
                    ProgressView().tint(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStopShape ? Strings.stopBroadcast : Strings.startBroadcast)
        .animation(.easeInOut(duration: 0.2), value: isStopShape)
    }

    private var isStopShape: Bool {
        controller.state.isLive || controller.state.isBusy
    }

    private func circleButton(
        systemImage: String,
        label: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // A card, not the status panel: while this is on screen the panel still says Online, because
    // the stream still is.
    private func noticeCard(_ notice: BroadcastFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(notice.message, systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
            if let recovery = notice.recovery {
                Text(recovery)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(Strings.ok) { controller.dismissNotice() }
                .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.bottom, 8)
    }

    private func failureCard(_ failure: BroadcastFailure) -> some View {
        let actions = Self.cardActions(for: failure)
        return VStack(alignment: .leading, spacing: 10) {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
            if let recovery = failure.recovery {
                Text(recovery)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if actions.contains(.openSettings) {
                    Button(Strings.openSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if actions.contains(.editConfiguration) {
                    Button(Strings.editStreamKey) {
                        // Mirrors the background teardown: the screen is about to be popped, and
                        // the camera must not outlive it.
                        UIApplication.shared.isIdleTimerDisabled = false
                        Task {
                            await controller.shutDown()
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if actions.contains(.tryAgain) {
                    Button(Strings.tryAgain) {
                        Task { await controller.retry() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.bottom, 8)
    }

    enum FailureAction: Equatable {
        case openSettings
        case tryAgain
        case editConfiguration
    }

    // Kept pure and out of the view body so the choice is testable: offering the wrong action is
    // a button that cannot work — a retry that resends the rejected key, or no way back to edit it.
    nonisolated static func cardActions(for failure: BroadcastFailure) -> [FailureAction] {
        var actions: [FailureAction] = []
        if failure == .cameraAccessDenied || failure == .microphoneAccessDenied {
            actions.append(.openSettings)
        }
        if failure.requiresReconfiguration {
            actions.append(.editConfiguration)
        } else if failure.isUserRetryable {
            actions.append(.tryAgain)
        }
        return actions
    }
}

// MTHKViewRepresentable allocates an MTKView and a CIContext when constructed, so it must not be
// rebuilt on every body invalidation — the duration label ticks this view's body once a second.
private struct CameraPreview: View, Equatable {
    let session: HaishinKitStreamingSession

    var body: some View {
        MTHKViewRepresentable(previewSource: session, videoGravity: .resizeAspectFill)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.session === rhs.session }
}

// Owns the session and controller for one visit to this screen, opened on first use rather than in
// `init`: SwiftUI constructs the view struct — and this class with it — on every invalidation and
// keeps only the one it installed. A controller built in `init` outlives the struct it was discarded
// with, its event reader still attached to a session nothing else can reach; three of them were
// alive at once.
@MainActor
final class StreamScreen {
    private let endpoint: StreamEndpoint
    private var opened: (session: HaishinKitStreamingSession, controller: BroadcastController)?

    /// False for every construction SwiftUI throws away, which is all of them but one.
    var hasOpened: Bool { opened != nil }

    var session: HaishinKitStreamingSession { open().session }
    var controller: BroadcastController { open().controller }

    init(endpoint: StreamEndpoint) {
        self.endpoint = endpoint
    }

    private func open() -> (session: HaishinKitStreamingSession, controller: BroadcastController) {
        if let opened { return opened }
        let session = HaishinKitStreamingSession()
        let opened = (session: session, controller: BroadcastController(endpoint: endpoint, session: session))
        self.opened = opened
        return opened
    }
}

extension StreamStatistics {
    // Nil until something has actually been measured: both numbers start at zero, so a stream
    // that just went live would otherwise show "0 fps · 0 kbit/s" under a red Online dot.
    var onAirSummary: String? {
        onAirLine(frames: "fps", megabits: "Mbit/s", kilobits: "kbit/s", separator: " · ")
    }

    var onAirAccessibilityLabel: String? {
        onAirLine(
            frames: "frames per second",
            megabits: "megabits per second",
            kilobits: "kilobits per second",
            separator: ", "
        ).map { "Stream rate: \($0)" }
    }

    private func onAirLine(
        frames: String,
        megabits: String,
        kilobits: String,
        separator: String
    ) -> String? {
        guard (currentFrameRate ?? 0) != 0 || (currentBytesPerSecond ?? 0) != 0 else { return nil }
        var parts: [String] = []
        if let currentFrameRate {
            parts.append("\(currentFrameRate) \(frames)")
        }
        if let currentBytesPerSecond {
            let bits = currentBytesPerSecond * 8
            if bits >= 1_000_000 {
                parts.append(String(format: "%.1f", Double(bits) / 1_000_000) + " \(megabits)")
            } else {
                parts.append("\(bits / 1000) \(kilobits)")
            }
        }
        return parts.joined(separator: separator)
    }
}
