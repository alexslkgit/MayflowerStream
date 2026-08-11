import Foundation

/// A validated RTMP publish destination.
///
/// RTMP splits a destination in two: the client connects to an *application* on a server, then
/// publishes under a *stream name*. Twitch's ingest URLs are handed out as one string,
/// `rtmp://euw10.contribute.live-video.net/app/<stream key>`, where `app` is the application and
/// the stream key is the stream name. Keeping the two apart in the model — instead of passing one
/// string around and hoping the library splits it the same way we would — is what lets the
/// configuration screen tell the user which half is wrong.
struct StreamEndpoint: Hashable, Sendable {
    /// Everything up to and including the RTMP application, e.g. `rtmp://host/app`.
    let connectURL: String
    /// The RTMP stream name. For Twitch, the stream key.
    let streamKey: String
}

extension StreamEndpoint {
    /// Twitch's Irish ingest, the closest of its European ingests to Portugal.
    /// Taken from Twitch's own ingest list, https://ingest.twitch.tv/ingests, on 2026-08-11.
    static let twitchDefaultIngestURL = "rtmp://euw10.contribute.live-video.net/app"
}

/// Why a destination could not be built. Every case carries a message a non-technical user can act
/// on; `ValidationError` never reaches the screen in its raw form.
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
    /// Builds a destination from what the user typed, or explains why it cannot be built.
    ///
    /// Two conveniences, because both are what people actually do with a Twitch key:
    /// leading and trailing whitespace is stripped (stream keys are copied and pasted, and pick up
    /// a trailing space often enough to be worth handling), and a full ingest URL pasted into the
    /// address field with the key still on the end is split apart — but only when the key field is
    /// empty, so a deliberately nested RTMP application path is never mangled.
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
