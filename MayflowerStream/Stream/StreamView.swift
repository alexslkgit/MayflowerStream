//
//  StreamView.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import HaishinKit
import SwiftUI

/// Screen 2 — Main Stream.
///
/// The screen opens with nothing running. The camera starts on an explicit tap, which is also when
/// permission is asked for; the broadcast starts on a second tap. Page 3 of the task asks for a
/// preview as soon as this screen is reached, and page 4 forbids initialising anything on screen
/// load — two taps is what satisfies both, and it is also what lets the user frame the shot and
/// mute themselves before going live.
struct StreamView: View {
    @State private var screen: StreamScreen
    @State private var isShowingParameters = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    init(endpoint: StreamEndpoint) {
        _screen = State(initialValue: StreamScreen(endpoint: endpoint))
    }

    private var controller: BroadcastController { screen.controller }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if controller.isCapturing {
                // Everything except the top edge. Anything burned into the picture — the clock
                // overlay sits 24px from the frame's top — would otherwise land underneath the
                // system status bar and read as a rendering fault. The stream itself is unaffected;
                // this only decides where the preview starts on screen.
                MTHKViewRepresentable(previewSource: screen.session, videoGravity: .resizeAspectFill)
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
            } else {
                idlePlaceholder
            }

            VStack {
                statusPanel
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
        .navigationTitle("Broadcast")
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
        .onChange(of: controller.isCapturing) { _, isCapturing in
            UIApplication.shared.isIdleTimerDisabled = isCapturing
        }
        .onChange(of: scenePhase) { _, phase in
            if Self.shouldShutDown(on: phase) {
                UIApplication.shared.isIdleTimerDisabled = false
                Task { await controller.shutDown() }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await controller.shutDown() }
        }
    }

    /// The documented lifecycle strategy: the app does not broadcast in the background. Only
    /// `.background` counts — `.inactive` also fires while the system permission alert is on
    /// screen, and tearing the camera down there would fight the thing we just asked the user to
    /// allow.
    nonisolated static func shouldShutDown(on phase: ScenePhase) -> Bool {
        phase == .background
    }

    // MARK: - Pieces

    private var statusPanel: some View {
        StreamStatusPanel(
            state: controller.state,
            duration: controller.formattedDuration,
            // The task asks for the sheet on an Online panel specifically, and there is nothing
            // truthful to put in it before then.
            onTap: controller.state.isLive ? { isShowingParameters = true } : nil
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var idlePlaceholder: some View {
        VStack(spacing: 20) {
            Image(systemName: "video.circle")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.6))
            Text("The camera is off.")
                .foregroundStyle(.white.opacity(0.8))
            Button("Turn on the camera") {
                Task { await controller.startCapture() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    /// The record button sits in its own layer so it is centred on the screen, not centred between
    /// the side controls. Two buttons on the left and one on the right are not the same width, and
    /// balancing them with a pair of `Spacer()`s pushed the button 31pt to the right of centre.
    private var controls: some View {
        ZStack {
            HStack {
                HStack(spacing: 10) {
                    circleButton(
                        systemImage: controller.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                        label: controller.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone",
                        tint: controller.isMicrophoneMuted ? .red : .white
                    ) {
                        Task { await controller.toggleMicrophone() }
                    }

                    // What is drawn here is drawn into the outgoing frames as well.
                    circleButton(
                        systemImage: "clock.fill",
                        label: controller.isClockOverlayVisible ? "Hide the clock overlay" : "Show the clock overlay",
                        tint: controller.isClockOverlayVisible ? .yellow : .white
                    ) {
                        Task { await controller.toggleClockOverlay() }
                    }
                }

                Spacer()

                circleButton(
                    systemImage: "arrow.triangle.2.circlepath.camera.fill",
                    label: "Switch camera",
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
        .accessibilityLabel(isStopShape ? "Stop broadcast" : "Start broadcast")
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

    /// Something went wrong that did not stop the broadcast. It is a card and not the status panel
    /// on purpose: while this is on screen the panel still says Online, because the stream still is.
    private func noticeCard(_ notice: BroadcastFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(notice.message, systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
            if let recovery = notice.recovery {
                Text(recovery)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("OK") { controller.dismissNotice() }
                .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.bottom, 8)
    }

    private func failureCard(_ failure: BroadcastFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
            if let recovery = failure.recovery {
                Text(recovery)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if isPermissionFailure(failure) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if failure.isUserRetryable {
                    Button("Try again") {
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

    private func isPermissionFailure(_ failure: BroadcastFailure) -> Bool {
        failure == .cameraAccessDenied || failure == .microphoneAccessDenied
    }
}

/// Owns the session and the controller for one visit to this screen.
///
/// It exists because SwiftUI recreates view structs freely and both of these must be created once.
/// Constructing it is cheap on purpose — `HaishinKitStreamingSession` builds nothing until capture
/// is started.
@MainActor
final class StreamScreen {
    let session: HaishinKitStreamingSession
    let controller: BroadcastController

    init(endpoint: StreamEndpoint) {
        let session = HaishinKitStreamingSession()
        self.session = session
        self.controller = BroadcastController(endpoint: endpoint, session: session)
    }
}
