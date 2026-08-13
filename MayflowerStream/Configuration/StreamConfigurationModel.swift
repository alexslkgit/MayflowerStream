import Foundation

/// Screen 1. Holds what the user typed, validates it when they try to move on, and hands a
/// validated destination to screen 2.
///
/// Validation runs on submit rather than on every keystroke: a stream key is half-typed for most
/// of the time it exists, and marking it invalid while it is being pasted is noise, not help.
@MainActor
@Observable
final class StreamConfigurationModel {
    var ingestURL: String
    var streamKey: String

    /// Set once the entry validates and has been saved. Screen 2 is pushed when this is non-nil.
    var endpoint: StreamEndpoint?

    /// What went wrong with the last attempt to continue, in words for the user.
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

    /// Only an empty screen keeps the button out of reach. A missing key is a thing to be told
    /// about on submit, not silently prevented — and an address pasted with the key still on the
    /// end is a valid entry with an empty key field, which a stricter gate would refuse.
    var canContinue: Bool {
        !ingestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Clears the last complaint. Called as the user edits, so a message never outlives the entry
    /// that caused it.
    func entryChanged() {
        problem = nil
    }

    func saveAndContinue() {
        do {
            let endpoint = try StreamEndpoint.make(ingestURL: ingestURL, streamKey: streamKey)
            try store.save(StreamSettings(ingestURL: endpoint.connectURL, streamKey: endpoint.streamKey))

            // Only now write the normalised values back, so the user sees exactly what will be
            // used — if a pasted URL was split, that has to be visible. It happens after the save
            // because the screen clears the last complaint whenever these fields change, which
            // would wipe the message a failed save had just produced.
            ingestURL = endpoint.connectURL
            streamKey = endpoint.streamKey
            problem = nil
            self.endpoint = endpoint
        } catch let error as StreamEndpointError {
            problem = Problem(message: error.localizedDescription, suggestion: error.recoverySuggestion)
        } catch {
            // Saving failed but the entry itself is fine. Say so, and do not pretend it was saved.
            let localized = error as? LocalizedError
            problem = Problem(
                message: localized?.errorDescription ?? "Your settings could not be saved.",
                suggestion: localized?.recoverySuggestion
            )
        }
    }
}
