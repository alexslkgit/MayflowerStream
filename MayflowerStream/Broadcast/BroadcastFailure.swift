//
//  BroadcastFailure.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

/// Everything that can go wrong, translated at the edge into what the user cares about rather
/// than RTMP/`AVCaptureSession`/keychain error shapes.
enum BroadcastFailure: Error, Equatable, Sendable {

    // Permissions and hardware
    case cameraAccessDenied
    case microphoneAccessDenied
    /// Screen Time or a management profile decided this, not the user — kept apart from `denied`
    /// because there is no Settings switch to point at.
    case cameraAccessRestricted
    case microphoneAccessRestricted
    case cameraMissing(CameraFacing)
    case cameraUnavailable
    case microphoneUnavailable
    /// The system refused a recording audio session, usually another app holding it — distinct from
    /// a microphone that will not open.
    case audioSessionUnavailable
    /// System paused the camera (call, another app); frames resume on their own, so this is a
    /// notice, not a stopped broadcast.
    case captureInterrupted

    // Configuration
    case unsupportedConfiguration(reason: String)
    /// Encoder refused the settings at runtime — `unsupportedConfiguration` is caught earlier, by validation.
    case encoderConfigurationFailed

    // Connection
    case serverUnreachable
    case connectionTimedOut
    case streamKeyRejected
    case serverRefused
    case connectionLost
    case reconnectionGaveUp(attempts: Int)

    /// Carries the raw text for diagnostics; the user-facing message stays plain.
    case unexpected(detail: String)
}

enum CameraFacing: String, Equatable, Sendable {
    case front, back

    var describedForUser: String {
        switch self {
        case .front: "front"
        case .back: "back"
        }
    }
}

extension BroadcastFailure {
    /// One sentence, no jargon. This is what goes on the screen.
    var message: String {
        switch self {
        case .cameraAccessDenied:
            "This app does not have permission to use the camera."
        case .microphoneAccessDenied:
            "This app does not have permission to use the microphone."
        case .cameraAccessRestricted:
            "Camera access is blocked by a restriction on this device."
        case .microphoneAccessRestricted:
            "Microphone access is blocked by a restriction on this device."
        case .cameraMissing(let facing):
            "This device has no \(facing.describedForUser) camera."
        case .cameraUnavailable:
            "The camera could not be started."
        case .microphoneUnavailable:
            "The microphone could not be started."
        case .audioSessionUnavailable:
            "Sound could not be prepared for recording."
        case .captureInterrupted:
            "The system paused the camera."
        case .unsupportedConfiguration(let reason):
            reason
        case .encoderConfigurationFailed:
            "The video encoder could not be set up on this device."
        case .serverUnreachable:
            "The streaming server could not be reached."
        case .connectionTimedOut:
            "The streaming server did not answer in time."
        case .streamKeyRejected:
            "The server did not accept your stream key."
        case .serverRefused:
            "The server refused the broadcast."
        case .connectionLost:
            "The connection to the streaming server was lost."
        case .reconnectionGaveUp(let attempts):
            "The connection was lost and could not be re-established after \(attempts) attempts."
        case .unexpected:
            "The broadcast stopped because of an unexpected problem."
        }
    }

    var recovery: String? {
        switch self {
        case .cameraAccessDenied, .microphoneAccessDenied:
            "Open Settings to allow it, then come back and try again."
        case .cameraAccessRestricted, .microphoneAccessRestricted:
            "Screen Time or a profile that manages this device is blocking it. Whoever set that up has to allow it."
        case .cameraMissing:
            "Check that this device has a camera on that side, then try again."
        case .cameraUnavailable:
            "Close any other app that might be using the camera and try again."
        case .microphoneUnavailable:
            "Close any other app that might be using the microphone and try again."
        case .audioSessionUnavailable:
            "Stop any other app that is playing or recording sound, then try again."
        case .captureInterrupted:
            "A call or another app is using it. The picture comes back on its own when they are done."
        case .unsupportedConfiguration:
            nil
        case .encoderConfigurationFailed:
            "Try again. If it keeps happening, restart the app."
        case .serverUnreachable, .connectionTimedOut:
            "Check your internet connection and try again."
        case .streamKeyRejected:
            "Check the stream key on the setup screen — it may have been reset."
        case .serverRefused:
            "Check the server address and stream key on the setup screen."
        case .connectionLost, .reconnectionGaveUp:
            "Tap to try again."
        case .unexpected:
            "Try again. If it keeps happening, restart the app."
        }
    }

    /// A rejected key or refused broadcast will fail again immediately, so only drops and timeouts retry.
    var isWorthRetrying: Bool {
        switch self {
        case .connectionLost, .connectionTimedOut, .serverUnreachable:
            true
        case .cameraAccessDenied, .microphoneAccessDenied, .cameraAccessRestricted,
             .microphoneAccessRestricted, .cameraMissing, .cameraUnavailable,
             .microphoneUnavailable, .audioSessionUnavailable, .captureInterrupted,
             .unsupportedConfiguration, .encoderConfigurationFailed, .streamKeyRejected,
             .serverRefused, .reconnectionGaveUp, .unexpected:
            false
        }
    }

    /// Decides what "Try again" retries — the camera being open says nothing about which of the two failed.
    var isDeviceProblem: Bool {
        switch self {
        case .cameraAccessDenied, .microphoneAccessDenied, .cameraAccessRestricted,
             .microphoneAccessRestricted, .cameraMissing, .cameraUnavailable,
             .microphoneUnavailable, .audioSessionUnavailable, .captureInterrupted,
             .encoderConfigurationFailed:
            true
        case .unsupportedConfiguration, .serverUnreachable, .connectionTimedOut, .streamKeyRejected,
             .serverRefused, .connectionLost, .reconnectionGaveUp, .unexpected:
            false
        }
    }

    /// Retrying resends the same configuration and fails the same way, so the fix is on the setup screen.
    var requiresReconfiguration: Bool {
        switch self {
        case .streamKeyRejected:
            true
        case .cameraAccessDenied, .microphoneAccessDenied, .cameraAccessRestricted,
             .microphoneAccessRestricted, .cameraMissing, .cameraUnavailable,
             .microphoneUnavailable, .audioSessionUnavailable, .captureInterrupted,
             .unsupportedConfiguration, .encoderConfigurationFailed, .serverUnreachable,
             .connectionTimedOut, .serverRefused, .connectionLost, .reconnectionGaveUp, .unexpected:
            false
        }
    }

    /// Listed case by case rather than `default`, so a new failure doesn't inherit a "Try again" nobody decided to give it.
    var isUserRetryable: Bool {
        switch self {
        case .cameraAccessDenied, .microphoneAccessDenied, .cameraMissing, .cameraUnavailable,
             .microphoneUnavailable, .audioSessionUnavailable, .encoderConfigurationFailed,
             .serverUnreachable, .connectionTimedOut, .streamKeyRejected, .serverRefused,
             .connectionLost, .reconnectionGaveUp, .unexpected:
            true
        // A restriction is not lifted by tapping again, and a paused camera comes back by itself.
        case .cameraAccessRestricted, .microphoneAccessRestricted, .captureInterrupted,
             .unsupportedConfiguration:
            false
        }
    }

    /// Never shown; this is what belongs in a log line or a bug report.
    var diagnosticDescription: String {
        switch self {
        case .unexpected(let detail): "unexpected: \(detail)"
        case .unsupportedConfiguration(let reason): "unsupportedConfiguration: \(reason)"
        default: String(describing: self)
        }
    }
}
