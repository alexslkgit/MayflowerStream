//
//  MediaPermissions.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import AVFoundation

enum MediaKind: Equatable, Sendable {
    case camera
    case microphone
}

enum MediaPermissionOutcome: Equatable, Sendable {
    case granted
    /// The user said no, and can say yes in Settings.
    case denied
    /// Screen Time or a management profile said no; nothing in Settings for this app changes it.
    case restricted
}

/// Behind a protocol so the denial paths can be tested.
protocol MediaPermissions: Sendable {
    /// Prompts only if never asked before; a prior refusal returns `.denied` without a prompt, so
    /// the UI has to offer a route to Settings instead.
    func requestAccess(to kind: MediaKind) async -> MediaPermissionOutcome
}

extension MediaPermissionOutcome {
    /// Kept here rather than at the two call sites so `.restricted` can't be quietly read as `.denied`
    /// and sent to a Settings switch that isn't there.
    func failure(for kind: MediaKind) -> BroadcastFailure? {
        switch self {
        case .granted:
            nil
        case .denied:
            kind == .camera ? .cameraAccessDenied : .microphoneAccessDenied
        case .restricted:
            kind == .camera ? .cameraAccessRestricted : .microphoneAccessRestricted
        }
    }
}

struct SystemMediaPermissions: MediaPermissions {
    func requestAccess(to kind: MediaKind) async -> MediaPermissionOutcome {
        let mediaType: AVMediaType = kind == .camera ? .video : .audio
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType) ? .granted : .denied
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }
}
