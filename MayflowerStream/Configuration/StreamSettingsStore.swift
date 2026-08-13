//
//  StreamSettingsStore.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation

/// What the user typed on the configuration screen, exactly as typed.
///
/// Deliberately not a `StreamEndpoint`: the screen has to be able to restore a half-finished or
/// even invalid entry, and validation happens when the user tries to move on, not when they type.
struct StreamSettings: Equatable, Sendable {
    var ingestURL: String
    var streamKey: String

    static let empty = StreamSettings(ingestURL: StreamEndpoint.twitchDefaultIngestURL, streamKey: "")
}

/// Main-actor bound on purpose: settings are read and written only while a screen is on screen,
/// so there is nothing here to make concurrency-safe.
@MainActor
protocol StreamSettingsStoring {
    func load() -> StreamSettings
    func save(_ settings: StreamSettings) throws
}

/// The real store. The ingest address is not a secret and lives in `UserDefaults`; the stream key
/// is a credential — anyone holding it can broadcast to the channel — so it lives in the keychain,
/// where an unencrypted device backup cannot read it.
@MainActor
struct KeychainStreamSettingsStore: StreamSettingsStoring {
    private let defaults: UserDefaults
    private let service: String
    private let account = "streamKey"
    private let ingestURLKey = "ingestURL"

    init(defaults: UserDefaults = .standard, service: String = "com.slobodianiuk.MayflowerStream") {
        self.defaults = defaults
        self.service = service
    }

    func load() -> StreamSettings {
        StreamSettings(
            ingestURL: defaults.string(forKey: ingestURLKey) ?? StreamEndpoint.twitchDefaultIngestURL,
            streamKey: loadStreamKey() ?? ""
        )
    }

    func save(_ settings: StreamSettings) throws {
        defaults.set(settings.ingestURL, forKey: ingestURLKey)
        try saveStreamKey(settings.streamKey)
    }

    // MARK: - Keychain

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func loadStreamKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveStreamKey(_ key: String) throws {
        guard !key.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let data = Data(key.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            // The app never streams in the background, so the key never needs to be readable while
            // the device is locked; see the lifecycle section of the README.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        let addStatus = SecItemAdd(baseQuery.merging(update) { $1 } as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Your stream key could not be saved to this device."
    }

    var recoverySuggestion: String? {
        "Try again. If it keeps happening, restarting the app usually clears it."
    }
}

/// Backs SwiftUI previews and unit tests, so neither touches the real keychain.
@MainActor
final class InMemoryStreamSettingsStore: StreamSettingsStoring {
    private var settings: StreamSettings
    /// Set to make `save` fail, so the "we could not save this" path can be exercised.
    var saveFailure: (any Error)?

    init(_ settings: StreamSettings = .empty) {
        self.settings = settings
    }

    func load() -> StreamSettings { settings }

    func save(_ settings: StreamSettings) throws {
        if let saveFailure { throw saveFailure }
        self.settings = settings
    }
}
