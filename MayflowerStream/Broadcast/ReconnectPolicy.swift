//
//  ReconnectPolicy.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation

/// How hard the app tries to re-establish a broadcast that dropped on its own.
///
/// The delay is a closure rather than a formula baked into the controller so tests can run the
/// whole reconnection sequence with no waiting at all. That is the only reason it is a closure.
struct ReconnectPolicy: Sendable {
    let maximumAttempts: Int
    let delay: @Sendable (_ attempt: Int) -> Duration

    /// Doubling backoff, capped at sixteen seconds: 1, 2, 4, 8, 16.
    /// Five attempts is a little over half a minute of trying, which is long enough to ride out a
    /// lift or a cell handover and short enough that the user is not left staring at
    /// "Reconnecting" wondering whether anything is happening.
    static let `default` = ReconnectPolicy(maximumAttempts: 5) { attempt in
        .seconds(min(16, 1 << max(0, attempt - 1)))
    }
}
