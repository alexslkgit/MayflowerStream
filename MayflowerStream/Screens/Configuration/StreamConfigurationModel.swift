//
//  StreamConfigurationModel.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation

// Validation runs on submit rather than on every keystroke: a stream key is half-typed for most
// of the time it exists, and marking it invalid while it is being pasted is noise, not help.
@MainActor
@Observable
final class StreamConfigurationModel {
    var ingestURL: String
    var streamKey: String

    // Set once the entry validates and has been saved; `navigationDestination(item:)` pushes
    // screen 2 as soon as this is non-nil.
    var endpoint: StreamEndpoint?

    private(set) var problem: Problem?

    private let store: any StreamSettingsStoring

    init(store: any StreamSettingsStoring) {
        self.store = store
        let saved = store.load()
        self.ingestURL = saved.ingestURL
        self.streamKey = saved.streamKey
    }

    struct Problem: Equatable {
        let message: String
        let suggestion: String?
    }

    // A missing key is reported on submit, not silently prevented: an address pasted with the
    // key still on the end is a valid entry with an empty key field, which a stricter gate on
    // both fields would wrongly refuse.
    var canContinue: Bool {
        !ingestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func entryChanged() {
        problem = nil
    }

    func saveAndContinue() {
        do {
            let endpoint = try StreamEndpoint.make(ingestURL: ingestURL, streamKey: streamKey)
            try store.save(StreamSettings(ingestURL: endpoint.connectURL, streamKey: endpoint.streamKey))

            // Written back only after the save succeeds: `entryChanged()` clears `problem` on
            // every field mutation, and writing these earlier would wipe a failed save's message.
            ingestURL = endpoint.connectURL
            streamKey = endpoint.streamKey
            problem = nil
            self.endpoint = endpoint
        } catch let error as StreamEndpointError {
            problem = Problem(message: error.localizedDescription, suggestion: error.recoverySuggestion)
        } catch {
            let localized = error as? LocalizedError
            problem = Problem(
                message: localized?.errorDescription ?? "Your settings could not be saved.",
                suggestion: localized?.recoverySuggestion
            )
        }
    }
}
