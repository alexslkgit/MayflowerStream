//
//  BroadcastFailure.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation

/// Everything that can go wrong, expressed in the vocabulary the user cares about rather than the
/// vocabulary the SDK uses.
///
/// This is the whole point of the type: RTMP status codes, `AVCaptureSession` errors, keychain
/// `OSStatus` values and network failures all arrive in different shapes, and every one of them
/// has to end up as a sentence on screen. Translating at the edge — where the raw failure is
/// still understood — means the UI never has to guess, and the state machine can be tested
/// against these cases without a camera or a server.
enum BroadcastFailure: Error, Equatable, Sendable {

    // Permissions and hardware
    case cameraAccessDenied
    case microphoneAccessDenied
    case cameraMissing(CameraFacing)
    case cameraUnavailable
    case microphoneUnavailable
    /// The system would not give the app a recording audio session — normally another app holding
    /// it, which is a different problem from a microphone that will not open.
    case audioSessionUnavailable

    // Configuration
    case unsupportedConfiguration(reason: String)
    /// The encoder refused the settings it was given. Distinct from `unsupportedConfiguration`,
    /// which is caught by validation before anything is opened.
    case encoderConfigurationFailed

    // Connection
    case serverUnreachable
    case connectionTimedOut
    case streamKeyRejected
    case serverRefused
    case connectionLost
    case reconnectionGaveUp(attempts: Int)

    /// Nothing above matched. Carries the raw text so it can still be read out of a screenshot,
    /// but the message shown to the user stays plain.
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
        case .cameraMissing(let facing):
            "This device has no \(facing.describedForUser) camera."
        case .cameraUnavailable:
            "The camera could not be started."
        case .microphoneUnavailable:
            "The microphone could not be started."
        case .audioSessionUnavailable:
            "Sound could not be prepared for recording."
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

    /// What the user can do about it, when there is something.
    var recovery: String? {
        switch self {
        case .cameraAccessDenied, .microphoneAccessDenied:
            "Open Settings to allow it, then come back and try again."
        case .cameraMissing:
            "Switch to the other camera."
        case .cameraUnavailable:
            "Close any other app that might be using the camera and try again."
        case .microphoneUnavailable:
            "Close any other app that might be using the microphone and try again."
        case .audioSessionUnavailable:
            "Stop any other app that is playing or recording sound, then try again."
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

    /// Whether losing the connection this way is worth retrying on the user's behalf.
    ///
    /// A rejected key or a refused broadcast will be rejected again a second later, so retrying
    /// only delays telling the user the truth. A dropped or timed-out connection is exactly what
    /// automatic reconnection exists for.
    var isWorthRetrying: Bool {
        switch self {
        case .connectionLost, .connectionTimedOut, .serverUnreachable:
            true
        case .cameraAccessDenied, .microphoneAccessDenied, .cameraMissing, .cameraUnavailable,
             .microphoneUnavailable, .audioSessionUnavailable, .unsupportedConfiguration,
             .encoderConfigurationFailed, .streamKeyRejected, .serverRefused, .reconnectionGaveUp,
             .unexpected:
            false
        }
    }

    /// Whether this is about the local camera and microphone rather than about the broadcast.
    ///
    /// It decides what "Try again" retries. That has to be read off the failure: the camera being
    /// open says nothing about which of the two things went wrong.
    var isDeviceProblem: Bool {
        switch self {
        case .cameraAccessDenied, .microphoneAccessDenied, .cameraMissing, .cameraUnavailable,
             .microphoneUnavailable, .audioSessionUnavailable, .encoderConfigurationFailed:
            true
        case .unsupportedConfiguration, .serverUnreachable, .connectionTimedOut, .streamKeyRejected,
             .serverRefused, .connectionLost, .reconnectionGaveUp, .unexpected:
            false
        }
    }

    /// Whether offering the user a "try again" button makes sense at all.
    var isUserRetryable: Bool {
        switch self {
        case .unsupportedConfiguration: false
        default: true
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
