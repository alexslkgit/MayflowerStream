//
//  StreamEndpointTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Testing

@testable import MayflowerStream

@Suite("Stream destination validation")
struct StreamEndpointTests {

    @Test("A Twitch ingest URL and key are kept apart, not concatenated")
    func splitsConnectURLFromStreamKey() throws {
        let endpoint = try StreamEndpoint.make(
            ingestURL: "rtmp://euw10.contribute.live-video.net/app",
            streamKey: "live_123456_abcdef"
        )
        #expect(endpoint.connectURL == "rtmp://euw10.contribute.live-video.net/app")
        #expect(endpoint.streamKey == "live_123456_abcdef")
    }

    @Test("A whole ingest URL pasted into the address field is split apart")
    func splitsAPastedFullURL() throws {
        let endpoint = try StreamEndpoint.make(
            ingestURL: "rtmp://euw10.contribute.live-video.net/app/live_123456_abcdef",
            streamKey: ""
        )
        #expect(endpoint.connectURL == "rtmp://euw10.contribute.live-video.net/app")
        #expect(endpoint.streamKey == "live_123456_abcdef")
    }

    @Test("A nested application path is left alone when the key field is filled in")
    func doesNotSplitWhenKeyIsProvided() throws {
        let endpoint = try StreamEndpoint.make(
            ingestURL: "rtmp://example.com/live/edge",
            streamKey: "mykey"
        )
        #expect(endpoint.connectURL == "rtmp://example.com/live/edge")
        #expect(endpoint.streamKey == "mykey")
    }

    @Test("Pasted whitespace is stripped from both fields")
    func trimsWhitespace() throws {
        let endpoint = try StreamEndpoint.make(
            ingestURL: "  rtmp://example.com/app \n",
            streamKey: "  mykey  "
        )
        #expect(endpoint.connectURL == "rtmp://example.com/app")
        #expect(endpoint.streamKey == "mykey")
    }

    @Test("rtmps is accepted")
    func acceptsRTMPS() throws {
        let endpoint = try StreamEndpoint.make(ingestURL: "rtmps://example.com:443/app", streamKey: "k")
        #expect(endpoint.connectURL == "rtmps://example.com:443/app")
    }

    @Test("Query strings and fragments are dropped rather than sent to the server")
    func stripsQueryAndFragment() throws {
        let endpoint = try StreamEndpoint.make(ingestURL: "rtmp://example.com/app?x=1#y", streamKey: "k")
        #expect(endpoint.connectURL == "rtmp://example.com/app")
    }

    // MARK: - Failures

    @Test("An empty address is refused before anything is attempted")
    func rejectsEmptyURL() {
        #expect(throws: StreamEndpointError.ingestURLMissing) {
            try StreamEndpoint.make(ingestURL: "   ", streamKey: "k")
        }
    }

    @Test("An address with no key anywhere is refused")
    func rejectsMissingKey() {
        #expect(throws: StreamEndpointError.streamKeyMissing) {
            try StreamEndpoint.make(ingestURL: "rtmp://example.com/app", streamKey: "")
        }
    }

    @Test("A non-RTMP address is refused, and the message names the protocol found")
    func rejectsUnsupportedScheme() {
        #expect(throws: StreamEndpointError.unsupportedScheme(found: "https")) {
            try StreamEndpoint.make(ingestURL: "https://example.com/app", streamKey: "k")
        }
    }

    @Test("An address with no application path is refused")
    func rejectsMissingApplicationPath() {
        #expect(throws: StreamEndpointError.missingApplicationPath) {
            try StreamEndpoint.make(ingestURL: "rtmp://example.com", streamKey: "k")
        }
    }

    @Test("Every failure carries a message with no jargon in it")
    func everyFailureIsExplainedInPlainWords() {
        let jargon = ["nil", "URLComponents", "OSStatus", "throw", "parse"]
        let failures: [StreamEndpointError] = [
            .ingestURLMissing, .streamKeyMissing, .ingestURLMalformed,
            .unsupportedScheme(found: "https"), .missingApplicationPath,
        ]
        for failure in failures {
            let message = failure.localizedDescription
            #expect(!message.isEmpty)
            #expect(failure.recoverySuggestion?.isEmpty == false)
            for term in jargon {
                #expect(!message.contains(term), "\(failure) leaks the word \(term) to the user")
            }
        }
    }
}
