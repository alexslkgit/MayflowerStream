# MayflowerStream

**Testing on a device? Please launch the app from the home screen, not under the Xcode
debugger.** The RTMP pipeline is soft real-time, and an attached debugger — Swift throw
interception, Main Thread Checker, Metal API validation, unoptimized package builds — can stall
the main thread for seconds at exactly the moments the app is recovering a dropped connection,
which then reads as a frozen UI and a stalled video pipeline. None of this happens untethered.
HaishinKit's maintainer has closed several identical freeze reports the same way (upstream
issues #1574, #1722: reproducible only under Xcode). Install once, stop the debug session, and
drive the app standalone.

An iOS app that broadcasts the camera and the microphone to Twitch over RTMP.

Two screens. The first collects an ingest address and a stream key and remembers them. The second
shows the camera, sends it out on a tap, and never leaves the user guessing whether the broadcast is
actually live.

- iOS 17.0+, Swift 6, SwiftUI
- [HaishinKit 2.2.5](https://github.com/shogo4405/HaishinKit.swift) for RTMP, pinned up to the next
  minor version
- H.264 video, AAC audio, 720×1280 at 30 fps and 2.5 Mbps

HaishinKit 2.2.5 has a known ordering hazard: it forwards each media buffer in its own
unstructured `Task`, so buffers can in theory be delivered out of order (upstream issue #1889,
fixed in 2.3.0, not back-ported to the 2.2.x line). This app's wiring tolerates it in practice;
moving to 2.3.0 once it stabilizes is the upgrade path.

## Running it

Open `MayflowerStream.xcodeproj` and run the `MayflowerStream` scheme. The camera and the
microphone only exist on a real device, so the simulator is good for the configuration screen, the
state machine and the tests, and nothing else. Running on a real device requires selecting your own
development team under Signing & Capabilities; the project does not pin one.

To broadcast, enter a stream key from **Twitch → Creator Dashboard → Settings → Stream**. The
ingest address is filled in already; Twitch lists the alternatives at
[ingest.twitch.tv](https://ingest.twitch.tv/ingests). A full ingest URL pasted into the address
field with the key still on the end is split into its two halves rather than rejected.

Tests:

```
xcodebuild -project MayflowerStream.xcodeproj -scheme MayflowerStream \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## The architecture in a paragraph

`StreamConfigurationModel` owns screen 1 and produces a validated `StreamEndpoint`.
`BroadcastController` owns screen 2: it is the state machine, the duration, and the translation of
everything that goes wrong into a sentence a person can read. Below it sits one protocol,
`StreamingSession`, and one implementation of it, `HaishinKitStreamingSession`, which is the only
file in the app that knows RTMP exists. That single seam is what lets every state transition and
every error path be tested on a machine with no camera, no microphone and no server — the whole
suite runs without a single piece of hardware attached. `BroadcastFailure` is the vocabulary the
two halves share: RTMP status codes, `AVCaptureSession` errors and keychain `OSStatus` values are
translated at the edge, where the raw failure is still understood, so the UI never has to guess.

The state machine has five states — Offline, Connecting, Online, Reconnecting, Error — and they are
about the *remote stream*, never about the local camera. A running preview with a dead connection is
Offline, and the panel says Offline. A camera that will not switch while the broadcast is healthy
does not touch the state at all; it gets its own card on screen, because telling a live broadcaster
their stream has stopped when it has not is the exact failure the task warns about.

## Decisions worth explaining

### The camera starts on a second tap

Page 3 of the brief says the main screen shows a camera preview; page 4 says nothing should be
initialised when the screen loads and permissions should be requested only when needed. Those pull
in opposite directions, so the app takes the strict reading: the screen opens with a *Turn on the
camera* button, and the tap is both the initialisation and the permission prompt. The broadcast is a
second, separate tap.

The strict reading is also the useful one. It gives the user a moment to frame the shot and mute
themselves before going out live, and it keeps `HaishinKitStreamingSession` from building anything
during a SwiftUI view evaluation — `RTMPStream.init` starts a background task that registers with
its connection, so a pipeline built on `onAppear` would leave a live object behind every time
SwiftUI re-evaluated the view. That is precisely the leak the brief asks about.

### Lifecycle: the app does not broadcast in the background

On `.background` the app stops publishing, closes the connection and releases the camera and the
microphone. Coming back to the foreground leaves the user Offline with the camera off, ready to
start again — nothing resumes behind their back. That covers the preview too: the task asks for
camera activation only on an explicit action, and a return to the foreground is treated as a fresh
screen rather than proof that the earlier tap still applies — one tap brings the preview back.

Only `.background` counts. `.inactive` also fires while the system permission alert is on screen,
and tearing the pipeline down there would fight the very thing the user was just asked to allow.

A related situation is the system taking the camera away mid-session — a phone call, another app
claiming capture. The session surfaces the capture interruption as an event, and the screen shows a
notice saying the system paused the camera; when the interruption ends the notice removes itself.
The broadcast state is not touched — it keeps describing the remote stream, not the local camera.

Because nothing streams while the device is locked, the stream key is stored with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — the strictest keychain class that still works, and
one that keeps the key out of an unencrypted backup and off any other device.

One thing survives a background cycle on purpose: the task reading `StreamingSession.events`. It is
started once, in `init`, and never cancelled — cancelling the consumer of an `AsyncStream` finishes
that stream permanently, and a reader started afterwards receives nothing at all. An app that did
that would publish frames while the screen said Connecting for ever.

### Portrait only, and what landscape would take

The app is locked to portrait, which the brief explicitly allows. The hard part of rotation is not
the layout; it is that the preview and the outgoing picture must rotate *together*. The preview is
an `MTHKView` fed by the mixer, and the encoder is fed by the same mixer, so supporting landscape
means driving `videoOrientation` on the capture connection from the interface orientation, swapping
the configured `videoSize` (720×1280 becomes 1280×720) and re-applying the encoder settings, and
deciding what happens to a broadcast that is already live — Twitch will accept a mid-stream
resolution change, but players handle it badly, so the honest options are to lock the orientation at
the moment the broadcast starts or to letterbox. That decision belongs with a product owner, and
locking to portrait is the version that cannot be wrong.

### The parameters sheet, and how the settings are verified

Tapping the status panel while Online opens a sheet listing every configured parameter beside what
the encoder reports it is actually using: resolution, video bitrate, audio bitrate and both codecs
are read back out of `RTMPStream.videoSettings` and `audioSettings` rather than assumed. When any of
them disagree, both numbers are shown, the row is orange, and the summary line says so. That is the
honest version of "guarantee the stream matches the configured settings" — if the encoder ever does
something else, the user sees it instead of being reassured.

The frame rate and the data rate are the measured numbers in the sheet — what the camera delivered
and what actually left the device over the last second, not settings read back. They are shown next
to the configured values and never flagged, because a camera producing 29 of the 30 frames it was
asked for is an ordinary healthy broadcast, not a misconfigured encoder.

Those same two numbers are on the broadcast screen itself: while the stream is Online, a small
capsule under the status panel shows the measured frame rate and outgoing data rate, refreshed every
second. The data rate is the whole stream on the wire — audio and RTMP overhead included — which is
why it reads a little above the configured 2.5 Mbps video bitrate rather than matching it. Nothing
is shown there until the first measurement arrives, because the library's network monitor ticks once
a second and starts at zero, and a HUD reading "0 fps · 0 kbit/s" under a live indicator would say
the opposite of what is happening.

### The quality settings are a constant, and `validate()` is there anyway

`BroadcastConfiguration.default` is fixed: 720×1280, 2.5 Mbps, 128 kbps AAC, 30 fps, 2-second
keyframes. There is no settings screen, so today `validate()` can never fail. It exists because the
moment there is one — and "let the user pick a quality" is the obvious next ticket — the limits it
checks (Twitch's published ones) are what stop the app from opening a broadcast the server will
drop, and it fails with a sentence the user can act on instead of an error from inside the encoder.
It is covered by tests now, so it is already trustworthy on the day a settings screen exists to
call it.

Codecs are not settings: the brief fixes them at H.264 and AAC, so they are constants and are
reported to the user rather than chosen by them.

### Where an overlay plugs in

`StreamingSession.setOverlay(_:)`, with `StreamOverlay` as the protocol and `ClockOverlay` as a
worked example — the clock button on the broadcast screen turns it on, and it is off by default.

The mechanism is `MediaMixer.screen`. Setting `videoMixerSettings.mode` to `.offscreen` makes the
mixer compose each frame itself, and anything added as a child of that screen is drawn on top. The
mode is entered once, at capture start: flipping it mid-flight rebuilds the video encoder and steps
timestamps backward across clock domains, which interrupts both the preview and the outgoing stream
for about a second — so the mixer composes for the whole life of a capture, and toggling the clock
is a constant-time add or remove of one screen object. The
composited frame is then what *every* output receives, so a single overlay lands in the encoded
stream and in the on-screen preview at once — what the broadcaster sees is what the viewers see. A
`MediaMixerOutput` cannot do this: an output only receives finished frames and cannot change them.

A richer *text* overlay — a longer caption, a viewer count, a lower third — is the same protocol
with a different implementation; only `HaishinKitStreamingSession` learns how to draw a new kind.
An overlay whose content is an image is not a drop-in: `StreamOverlay`'s only content method,
`text(at:)`, returns a `String`, and `HaishinKitStreamingSession` hard-wires a `TextScreenObject`,
so an image overlay would need the protocol to grow an image-content requirement first — HaishinKit
already has `ImageScreenObject` for the rendering side, so only the protocol boundary is missing.

The same two seams the overlay uses would carry most of what comes next. Local recording would be
a `StreamRecorder` added as another mixer output, sitting next to the encoder rather than replacing
it. Video filters would be a `VideoEffect` registered on the same offscreen rendering the capture
already runs, so they would compose with an overlay rather than compete with it. A
different wire protocol, such as SRT, would be another `StreamingSession` implementation behind the
existing one, with everything above the seam — the state machine, the parameters sheet, the UI —
unaware which one is running.

### Reconnection

A connection that drops on its own is re-established without asking: five attempts, 1, 2, 4, 8 and
16 seconds apart. Those waits are for a network that is still away — once the device reports a path
again, the wait that is running is dropped and so is every wait after it, for as long as the path
stays up, so coming out of a lift or off airplane mode does not leave the user watching a backoff
that has nothing left to wait for. Attempts against a live path either succeed or fail quickly, and
if the path goes away again the waiting comes back with it. The waiting is the only thing
reachability decides; whether the broadcast is back is still the server's answer. The one delay I cannot shorten is an attempt already in flight when the network
returns: HaishinKit's connect timer is a hardcoded 15 seconds, so that is the worst case before the
next attempt. A failure that cannot succeed on a second try — a rejected stream key, a refused
broadcast — is not retried at all, because retrying only delays telling the user the truth. The
duration keeps counting through a reconnection: it is the length of the broadcast, not the length of
the current TCP connection.

## What is not covered by tests

The tests cover the state machine, the configuration screen, the endpoint parsing, the keychain
store and the failure vocabulary, and they were checked by reintroducing each defect they were
written for and confirming the suite went red.

`HaishinKitStreamingSession` itself needs a camera and a server, so it is verified on a device
instead. The protocol contract it has to honour — a failed `startPublishing` leaves nothing open, so
the next attempt can succeed — is written on the protocol and pinned by the fake session, but a
regression inside the real adapter would not turn the suite red. That is the honest boundary of
what can be tested without hardware.

## How the work went

The build order followed the dependency graph rather than the screen order: the settings screen
first, since it depends on nothing else; then the broadcast state machine and its failure taxonomy,
written and tested without any hardware attached; then the HaishinKit layer — H.264 and AAC
configured, RTMP status codes mapped to the human-readable errors the state machine expects — behind
the `StreamingSession` seam; then the main screen, which by that point was mostly wiring. A
deliberate hardening pass followed once the pieces were assembled, and it turned up real bugs: races
between confirmation events and calls still in flight, and lifecycle edge cases around backgrounding.
Each fix was pinned by a test that was watched failing on the code as it stood before the fix, never
written after the fact to match it. The rule behind that, held throughout: no behavioral test was
accepted into the suite without being seen red on the specific defect it guards — a test that has
never failed proves nothing about the code, only about itself. The last step was live verification
against a real Twitch channel, walking both the success path and the failure paths, including a
deliberately wrong stream key, to see the rejection surface as the sentence a user would actually
read.

AI tools were part of that process, used as an instrument rather than a source of decisions: every
architectural choice, every line and every comment here was written or reviewed by hand and is one
the author can defend. The test suite was held to the same standard as the rest of the app — proven
by breaking the code and watching the test catch it, not trusted because it came back green.
