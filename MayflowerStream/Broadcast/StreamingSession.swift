import Foundation

/// Everything the app needs from a streaming library, and nothing else.
///
/// This is the one seam in the app, and it earns its place three times over. It keeps HaishinKit's
/// actor-isolated API out of the view layer; it lets the state machine and every error path be
/// tested without a camera, a microphone or a server; and it is where a frame-processing step —
/// a clock burned into the outgoing picture, say — would be added, because that is the only place
/// frames pass through on their way from the capture session to the encoder.
///
/// Capture and publishing are deliberately separate. The user gets a preview before going live,
/// and stopping a broadcast leaves the camera running so it can be started again immediately.
protocol StreamingSession: Sendable {

    /// Established once, when the session is created. **Iterate exactly once.**
    /// HaishinKit's own status streams re-arm their continuation on every read of the property,
    /// which silently disconnects the previous reader — so this is a stored stream, not a computed
    /// one, and the controller owns the single task that drains it.
    var events: AsyncStream<StreamingEvent> { get }

    /// Opens the camera and microphone. Nothing before this call touches AVFoundation.
    func startCapture(_ configuration: BroadcastConfiguration) async throws(BroadcastFailure)

    /// Closes the camera and microphone and releases everything held by the session.
    /// Safe to call when capture was never started.
    func stopCapture() async

    func switchCamera(to facing: CameraFacing) async throws(BroadcastFailure)

    func setMicrophoneMuted(_ isMuted: Bool) async

    /// Connects and begins publishing. Throws if the server rejects the attempt outright; a
    /// connection that succeeds and then drops arrives as a `.disconnected` event instead.
    func startPublishing(to endpoint: StreamEndpoint) async throws(BroadcastFailure)

    /// Stops publishing and closes the connection, leaving capture running.
    func stopPublishing() async

    /// What is actually going out right now, for the parameters sheet.
    func currentStatistics() async -> StreamStatistics
}

/// Things that happen to the session without the app asking.
enum StreamingEvent: Equatable, Sendable {
    /// The server accepted the stream and frames are going out.
    case publishing
    /// The connection ended on its own. The reason is already translated for the user.
    case disconnected(BroadcastFailure)
}

/// A snapshot of the outgoing stream, shown in the parameters sheet.
///
/// `configured` is what was asked for and `actual` is what the encoder reports it is doing. They
/// are kept apart on purpose: the task asks for the real outgoing stream to match the configured
/// settings, and the only honest way to show that is to show both numbers.
struct StreamStatistics: Equatable, Sendable {
    var configured: BroadcastConfiguration
    var actualVideoBitRate: Int?
    var actualAudioBitRate: Int?
    var actualVideoSize: CGSize?
    var totalBytesSent: Int64?

    init(
        configured: BroadcastConfiguration,
        actualVideoBitRate: Int? = nil,
        actualAudioBitRate: Int? = nil,
        actualVideoSize: CGSize? = nil,
        totalBytesSent: Int64? = nil
    ) {
        self.configured = configured
        self.actualVideoBitRate = actualVideoBitRate
        self.actualAudioBitRate = actualAudioBitRate
        self.actualVideoSize = actualVideoSize
        self.totalBytesSent = totalBytesSent
    }
}
