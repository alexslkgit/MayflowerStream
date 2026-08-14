//
//  StreamEndpoint.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import Foundation

// RTMP splits a destination in two: the client connects to an *application* on a server, then
// publishes under a *stream name*. Twitch hands out both as one string
// (rtmp://host/app/<stream key>), which is why they are kept apart here instead of relying on
// the library to split them the same way.
struct StreamEndpoint: Hashable, Sendable {
    let connectURL: String
    let streamKey: String
}

extension StreamEndpoint {
    // Twitch's Irish ingest, the closest of its European ingests to Portugal — see
    // https://ingest.twitch.tv/ingests, checked 2026-08-11.
    static let twitchDefaultIngestURL = "rtmp://euw10.contribute.live-video.net/app"
}

enum StreamEndpointError: Error, Equatable {
    case ingestURLMissing
    case streamKeyMissing
    case ingestURLMalformed
    case unsupportedScheme(found: String)
    case missingApplicationPath
}

extension StreamEndpointError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .ingestURLMissing:
            "Enter the server address you want to broadcast to."
        case .streamKeyMissing:
            "Enter your stream key."
        case .ingestURLMalformed:
            "That server address is not a valid link."
        case .unsupportedScheme(let found):
            "This app can only broadcast over RTMP, and that address uses \(found)."
        case .missingApplicationPath:
            "That server address is missing the part after the host name."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .ingestURLMissing, .ingestURLMalformed, .missingApplicationPath:
            "A Twitch address looks like rtmp://euw10.contribute.live-video.net/app"
        case .streamKeyMissing:
            "Twitch shows it under Creator Dashboard → Settings → Stream."
        case .unsupportedScheme:
            "Use an address starting with rtmp:// or rtmps://"
        }
    }
}

extension StreamEndpoint {
    // A pasted ingest URL with the key still on the end is split apart only when the key field
    // is empty, so a deliberately nested RTMP application path is never mangled.
    static func make(ingestURL rawURL: String, streamKey rawKey: String) throws(StreamEndpointError) -> StreamEndpoint {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else { throw .ingestURLMissing }
        guard var components = URLComponents(string: trimmedURL), let host = components.host, !host.isEmpty else {
            throw .ingestURLMalformed
        }

        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "rtmp" || scheme == "rtmps" else {
            throw .unsupportedScheme(found: scheme.isEmpty ? "no protocol" : scheme)
        }

        var pathSegments = components.path.split(separator: "/").map(String.init)
        guard !pathSegments.isEmpty else { throw .missingApplicationPath }

        var streamKey = trimmedKey
        if streamKey.isEmpty, pathSegments.count > 1 {
            streamKey = pathSegments.removeLast()
        }
        guard !streamKey.isEmpty else { throw .streamKeyMissing }

        components.path = "/" + pathSegments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let connectURL = components.string else { throw .ingestURLMalformed }

        return StreamEndpoint(connectURL: connectURL, streamKey: streamKey)
    }
}
