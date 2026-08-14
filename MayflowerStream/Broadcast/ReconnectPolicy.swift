//
//  ReconnectPolicy.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation
import Network

/// The delay is a closure rather than a formula baked into the controller, so tests can run a
/// whole reconnection sequence with no waiting.
struct ReconnectPolicy: Sendable {
    let maximumAttempts: Int
    let delay: @Sendable (_ attempt: Int) -> Duration

    /// Doubling backoff capped at 16s (1, 2, 4, 8, 16); 5 attempts is a bit over half a minute.
    static let `default` = ReconnectPolicy(maximumAttempts: 5) { attempt in
        .seconds(min(16, 1 << max(0, attempt - 1)))
    }
}

protocol ConnectivityMonitor: Sendable {
    /// The first value is the path as it already is, so a caller waiting for the network to come
    /// back must see an unsatisfied update before it believes a satisfied one.
    func updates() async -> AsyncStream<Bool>
}

struct NetworkPathMonitor: ConnectivityMonitor {
    private static let queue = DispatchQueue(label: "MayflowerStream.connectivity")

    func updates() async -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: Self.queue)
        }
    }
}
