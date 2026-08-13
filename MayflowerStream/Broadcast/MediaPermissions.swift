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
    case denied
}

/// Asking for camera and microphone access, behind a protocol so the denial paths can be tested.
protocol MediaPermissions: Sendable {
    /// Prompts the user only if they have never been asked. If they have already refused, this
    /// returns `.denied` without showing anything, which is why the UI has to offer a route to
    /// Settings rather than another prompt.
    func requestAccess(to kind: MediaKind) async -> MediaPermissionOutcome
}

struct SystemMediaPermissions: MediaPermissions {
    func requestAccess(to kind: MediaKind) async -> MediaPermissionOutcome {
        let mediaType: AVMediaType = kind == .camera ? .video : .audio
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType) ? .granted : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }
}
