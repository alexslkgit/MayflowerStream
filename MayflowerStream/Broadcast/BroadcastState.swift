//
//  BroadcastState.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation

/// What the user is told the broadcast is doing.
///
/// The requirement behind this type is "never let users remain uncertain about whether their
/// stream is active", so the states are deliberately about the *remote* stream, not about the
/// local camera. A running preview with no connection is `.offline`, and the screen says so.
enum BroadcastState: Equatable, Sendable {
    /// Not broadcasting. The camera may or may not be running; that is a separate question.
    case offline
    /// On the user's request, unlike `.reconnecting`.
    case connecting
    /// The server has accepted the publish request. Nothing here confirms frames are still
    /// arriving — that would need sampling the outgoing bitrate, which this state does not do.
    case online
    /// The stream dropped on its own and is being re-established without the user asking.
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
