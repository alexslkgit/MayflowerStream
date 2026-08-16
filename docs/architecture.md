# The shape of the code

`StreamConfigurationModel` owns screen one and produces a validated `StreamEndpoint`.
`BroadcastController` owns screen two: the state machine, the duration, the reconnection ladder, and
the translation of everything that goes wrong into a sentence a person can read. Under it sits one
protocol, `StreamingSession`, with one real implementation, `HaishinKitStreamingSession`, which is
the only file in the app that knows RTMP exists.

That single seam is why every state transition and every error path can be tested on a machine with
no camera, no microphone and no server. `BroadcastFailure` is the vocabulary the two halves share:
RTMP status codes, `AVCaptureSession` errors and keychain `OSStatus` values are all translated at
the edge, where the raw failure is still understood, so the UI never has to guess what it is looking
at.

The state machine has five states, Offline, Connecting, Online, Reconnecting and Error, and they
describe the *remote stream* only. A running preview with a dead connection is Offline and the panel
says Offline. A camera that refuses to switch while the broadcast is healthy does not touch the
state at all; it gets its own card on screen. Telling a live broadcaster their stream has stopped
when it has not is the exact failure the brief warns about.

The same rule covers the system taking the camera away mid-session, a phone call or another app
claiming capture. The session reports the interruption as an event, the screen shows a notice
saying the system paused the camera, and the notice removes itself when the interruption ends. The
broadcast state is untouched, because the broadcast did not change.

What that seam buys the test suite is in [test-report.md](test-report.md); the decisions that shaped
it are in [decisions.md](decisions.md).

## What I would hang off this next

The overlay seam is the interesting one. `StreamingSession.setOverlay(_:)` takes a `StreamOverlay`,
and `ClockOverlay` is the worked example behind the clock button. The mechanism is
`MediaMixer.screen`: the composited frame is what *every* output receives, so one overlay lands in
the encoded stream and in the on-screen preview at once, and what the broadcaster sees is what the
viewers see. A `MediaMixerOutput` cannot do this, since an output only receives finished frames and
cannot change them. A richer text overlay is the same protocol with a different implementation. An
image overlay is not a drop-in: `StreamOverlay`'s only content method returns a `String` and the
session hard-wires a `TextScreenObject`, so the protocol would have to grow an image requirement
first. HaishinKit already has `ImageScreenObject`, so only the boundary is missing.

Local recording would be a recorder added as another mixer output, next to the encoder rather than
in place of it. Video filters would be a `VideoEffect` on the offscreen rendering the capture
already runs, so they would compose with an overlay instead of competing with it. A different wire
protocol, SRT for instance, would be another `StreamingSession` implementation behind the existing
seam, with the state machine, the parameters sheet and the UI unaware of which one is running.

## How the work went

I built along the dependency graph rather than the screen order. Settings screen first, since it
depends on nothing. Then the broadcast state machine and its failure taxonomy, written and tested
with no hardware attached at all. Then the HaishinKit layer behind the `StreamingSession` seam, with
RTMP status codes mapped onto the errors the state machine already expected. The main screen came
last and was mostly wiring by then.

A hardening pass followed, and it earned its place: races between confirmation events and calls
still in flight, lifecycle edge cases around backgrounding, and the publisher-displacement bug,
which only a real Twitch dashboard could have shown me. The last step was a live pass against a real
channel, walking the success path and the failure paths, so I could read the rejection sentence the
way a user would.
