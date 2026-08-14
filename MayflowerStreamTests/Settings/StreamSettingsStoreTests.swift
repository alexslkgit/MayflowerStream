//
//  StreamSettingsStoreTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import Foundation
import Testing

@testable import MayflowerStream

/// Run against the real keychain and `UserDefaults` — a fake keychain would only prove the fake — each with its own service name and defaults suite so nothing leaks between tests.
@MainActor
@Suite("Where the destination is kept")
struct StreamSettingsStoreTests {

    private static func makeStore(_ name: String) -> (KeychainStreamSettingsStore, UserDefaults) {
        let suite = "MayflowerStreamTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = KeychainStreamSettingsStore(defaults: defaults, service: "MayflowerStreamTests.\(name)")
        try? store.save(StreamSettings(ingestURL: StreamEndpoint.twitchDefaultIngestURL, streamKey: ""))
        return (store, defaults)
    }

    @Test("An empty store answers with Twitch's address and no key")
    func emptyStoreHasADefaultAddress() {
        let (store, _) = Self.makeStore(#function)

        #expect(store.load() == StreamSettings.empty)
    }

    @Test("What was saved is what comes back")
    func savedSettingsComeBack() throws {
        let (store, _) = Self.makeStore(#function)

        try store.save(StreamSettings(ingestURL: "rtmp://example.com/app", streamKey: "live_secret"))

        #expect(store.load() == StreamSettings(ingestURL: "rtmp://example.com/app", streamKey: "live_secret"))
    }

    @Test("Saving twice replaces the key rather than failing on the second one")
    func savingTwiceReplaces() throws {
        let (store, _) = Self.makeStore(#function)

        try store.save(StreamSettings(ingestURL: "rtmp://example.com/app", streamKey: "first"))
        try store.save(StreamSettings(ingestURL: "rtmp://example.com/app", streamKey: "second"))

        #expect(store.load().streamKey == "second")
    }

    @Test("Clearing the key removes it instead of storing an empty one")
    func clearingTheKeyRemovesIt() throws {
        let (store, _) = Self.makeStore(#function)
        try store.save(StreamSettings(ingestURL: "rtmp://example.com/app", streamKey: "live_secret"))

        try store.save(StreamSettings(ingestURL: "rtmp://example.com/app", streamKey: ""))

        #expect(store.load().streamKey == "")
    }

    @Test("The address is not a secret and does not go in the keychain")
    func theAddressLivesInDefaults() throws {
        let (store, defaults) = Self.makeStore(#function)

        try store.save(StreamSettings(ingestURL: "rtmp://example.com/app", streamKey: "live_secret"))

        #expect(defaults.string(forKey: "ingestURL") == "rtmp://example.com/app")
        for (_, value) in defaults.dictionaryRepresentation() {
            #expect((value as? String) != "live_secret", "the stream key was written to UserDefaults")
        }
    }
}
