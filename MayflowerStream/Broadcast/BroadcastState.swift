//
//  BroadcastState.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

/// States describe the *remote* stream, not the local camera: a running preview with no
/// connection is `.offline`.
enum BroadcastState: Equatable, Sendable {
    case offline
    /// On the user's request, unlike `.reconnecting`.
    case connecting
    /// Server accepted the publish request; does not confirm frames are still arriving.
    case online
    /// Dropped on its own and being re-established without the user asking.
    case reconnecting(attempt: Int)
    case failed(BroadcastFailure)
}

extension BroadcastState {
    var label: String {
        switch self {
        case .offline: "Offline"
        case .connecting: "Connecting"
        case .online: "Online"
        case .reconnecting: "Reconnecting"
        case .failed: "Error"
        }
    }

    var isLive: Bool {
        if case .online = self { return true }
        return false
    }

    /// Drives the progress indicator and keeps the start button out of reach.
    var isBusy: Bool {
        switch self {
        case .connecting, .reconnecting: true
        case .offline, .online, .failed: false
        }
    }

    var failure: BroadcastFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}
