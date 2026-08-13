import Foundation
import Testing

@testable import MayflowerStream

@MainActor
@Suite("Stream configuration screen")
struct StreamConfigurationModelTests {

    private static let validURL = "rtmp://euw10.contribute.live-video.net/app"

    @Test("The screen opens on whatever was saved last time")
    func restoresSavedEntry() {
        let store = InMemoryStreamSettingsStore(
            StreamSettings(ingestURL: Self.validURL, streamKey: "live_123")
        )
        let model = StreamConfigurationModel(store: store)

        #expect(model.ingestURL == Self.validURL)
        #expect(model.streamKey == "live_123")
        #expect(model.problem == nil)
        #expect(model.endpoint == nil)
    }

    @Test("Continue stays out of reach only while the address is empty")
    func continueNeedsAnAddress() {
        let model = StreamConfigurationModel(store: InMemoryStreamSettingsStore())

        model.ingestURL = ""
        model.streamKey = "live_123"
        #expect(model.canContinue == false)

        model.ingestURL = "   "
        #expect(model.canContinue == false, "whitespace is not an entry")

        model.ingestURL = Self.validURL
        model.streamKey = ""
        #expect(model.canContinue, "a pasted address carrying the key is a complete entry")
    }

    @Test("A missing stream key is explained rather than silently blocked")
    func missingKeyIsExplained() {
        let model = StreamConfigurationModel(store: InMemoryStreamSettingsStore())
        model.ingestURL = Self.validURL
        model.streamKey = ""

        model.saveAndContinue()

        #expect(model.endpoint == nil)
        #expect(model.problem?.message == StreamEndpointError.streamKeyMissing.errorDescription)
    }

    @Test("A valid entry is saved and becomes the destination for screen 2")
    func validEntryIsSavedAndPassedOn() throws {
        let store = InMemoryStreamSettingsStore()
        let model = StreamConfigurationModel(store: store)
        model.ingestURL = Self.validURL
        model.streamKey = "live_123"

        model.saveAndContinue()

        let endpoint = try #require(model.endpoint)
        #expect(endpoint.connectURL == Self.validURL)
        #expect(endpoint.streamKey == "live_123")
        #expect(store.load() == StreamSettings(ingestURL: Self.validURL, streamKey: "live_123"))
        #expect(model.problem == nil)
    }

    @Test("A whole ingest URL pasted into the address field is split, and the split is shown")
    func pastedURLIsSplitAndVisible() throws {
        let model = StreamConfigurationModel(store: InMemoryStreamSettingsStore())
        model.ingestURL = Self.validURL + "/live_123"
        model.streamKey = ""

        model.saveAndContinue()

        #expect(model.ingestURL == Self.validURL, "the user cannot see what will actually be used")
        #expect(model.streamKey == "live_123")
        #expect(try #require(model.endpoint).streamKey == "live_123")
    }

    @Test("A failed save is reported, and nothing on the screen wipes the message")
    func failedSaveKeepsItsMessage() {
        let store = InMemoryStreamSettingsStore()
        store.saveFailure = KeychainError(status: -25299)
        let model = StreamConfigurationModel(store: store)
        model.ingestURL = Self.validURL + "/live_123"
        model.streamKey = ""

        model.saveAndContinue()

        #expect(model.problem?.message == "Your stream key could not be saved to this device.")
        #expect(model.endpoint == nil, "a broadcast must not start from settings that were not saved")
        // The screen clears the message whenever these fields change. If saving rewrote them with
        // the normalised values, the message would be gone before the user could read it.
        #expect(model.ingestURL == Self.validURL + "/live_123")
        #expect(model.streamKey == "")
    }

    @Test("An entry that cannot be a destination never reaches the store")
    func invalidEntryIsNotSaved() {
        let store = InMemoryStreamSettingsStore()
        let model = StreamConfigurationModel(store: store)
        model.ingestURL = "https://example.com/app"
        model.streamKey = "live_123"

        model.saveAndContinue()

        #expect(model.endpoint == nil)
        #expect(model.problem?.message == StreamEndpointError.unsupportedScheme(found: "https").errorDescription)
        #expect(store.load() == StreamSettings.empty, "an invalid entry was written to the store")
    }

    @Test("Editing after a complaint clears it")
    func editingClearsTheComplaint() {
        let model = StreamConfigurationModel(store: InMemoryStreamSettingsStore())
        model.ingestURL = "not a url"
        model.streamKey = "live_123"
        model.saveAndContinue()
        #expect(model.problem != nil)

        model.entryChanged()

        #expect(model.problem == nil)
    }
}
