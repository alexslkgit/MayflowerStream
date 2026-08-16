# MayflowerStream

An iPhone app that sends the camera and the microphone to Twitch over RTMP. Two screens: one takes
an ingest address and a stream key and remembers them, the other shows the picture, puts it on air
on a tap, and never leaves you guessing whether you are actually live.

iOS 17.0, Swift 6, SwiftUI, and [HaishinKit 2.2.5](https://github.com/shogo4405/HaishinKit.swift)
for RTMP, pinned up to the next minor. H.264 video and AAC audio, 720×1280 at 30 fps, 2.5 Mbps video
and 128 kbps audio, 2-second keyframes. One known hazard in that version: it forwards each media
buffer in its own unstructured `Task`, so buffers can in theory arrive out of order (upstream #1889,
fixed in 2.3.0 and not back-ported). This wiring has never shown it, and 2.3.0 is the upgrade path.

## Two things before your first broadcast

**Run it off the home screen, not off Xcode.** The RTMP pipeline is soft real time and an attached
debugger is not: throw interception, the Main Thread Checker, Metal API validation and unoptimised
package builds each stall the main thread for seconds, and they pick their moment — usually the one
where the app is recovering a dropped connection. The frozen UI you get that way never happens
untethered, and HaishinKit's maintainer has closed several identical reports the same way (upstream
#1574, #1722). Install once, stop the debug session, launch from the home screen; everything below
was measured that way.

**Turn on Disconnect Protection for the channel**, under Creator Dashboard → Settings → Stream.
Continuity across an interruption is not a client-side property. With that toggle off, Twitch holds
nothing, and every blip is a new stream regardless of what this app, OBS, or anything else does. It
cost me two device passes and one confidently wrong root-cause theory to think of looking at it.

Signing, the simulator's limits, the Twitch walk-through, the wrong-key behaviour and the console
noise the frameworks print under Xcode are all in [docs/running.md](docs/running.md).

## What is worth knowing first

**One RTMP connection per broadcast.** Twitch accepts one live publisher per stream key, so a second
connection carrying the same key does not resume the first, it displaces it — and a session
displaced by its own replacement is not a drop the server holds open. Disconnect protection never
engages, and the uptime is back at zero after a three-second trip to the home screen. This cost me a
device pass to find. Keeping the one connection means the server sees no publisher change at all:
the video stops for as long as the app is away, then continues in the same stream and the same VOD.
An explicit Stop, or leaving the broadcast screen, does say goodbye; those exits are not coming back.

**Coming back from the background is flat at about three seconds, however long you were away.** It
used to be *equal* to the time away: away 73 s, picture frozen 74 s, preview and outgoing stream
dead together while the camera ran at 30 fps. HaishinKit's compositor latches its presentation
timestamp into the future if the camera is attached before the display link has ticked, and drops
every live frame in silence until the wall clock catches up. Starting the compositor first is the
whole fix; the hunt and the numbers are in [docs/background-recovery.md](docs/background-recovery.md).

**Half a second to a picture, about 1.3 seconds to being on air**, on an iPhone 13 Pro Max. A
connection that dies on its own is redialled on a five-rung ladder whose waits are cancelled the
moment the device reports a usable path again; the screen counts down to the next attempt rather
than looking hung, and the duration keeps counting through all of it: it is the age of the broadcast,
not of the current TCP connection. The tables are in [docs/performance.md](docs/performance.md).

**186 tests in 22 suites, all of them running with no camera, no microphone and no server.** They
cover the state machine and its races, the configuration screen, the endpoint parsing, the keychain
store, the failure vocabulary and the pure view predicates, through a `FakeStreamingSession` behind
the `StreamingSession` protocol that counts calls, scripts per-attempt publish failures and takes an
injectable delay on every slow call — so a race can be arranged rather than hoped for, and a
reconnection sequence with 31 seconds of backoff runs instantly. No behavioural test went in without
being watched failing on the specific defect it guards; where a fix already existed, the defect was
put back and the test observed going red before it went green. A test that has never failed proves
something about itself and nothing about the code.

The honest boundary: `HaishinKitStreamingSession` needs a camera and a real server, so a regression
inside the real adapter would not turn the suite red. That half was verified on a device instead,
and the live pass against a real channel walked the failure paths, deliberately wrong key included.

```
xcodebuild -project MayflowerStream.xcodeproj -scheme MayflowerStream \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Verification, and where the detail lives

What the suite cannot reach was measured on the device instead, twice, over one scripted scenario.

- [docs/background-recovery.md](docs/background-recovery.md) — the post-suspension freeze: the
  instrumented device run, the mechanism inside the library, the before/after numbers.
- [docs/memory-and-performance.md](docs/memory-and-performance.md) — leaks, footprint, sanitizers.
- [docs/test-report.md](docs/test-report.md) — what each test pins and what it looked like red.
- [docs/performance.md](docs/performance.md) — timings, the ladder, every kind of background trip.
- [docs/running.md](docs/running.md) — installing it and setting up the Twitch side.
- [docs/architecture.md](docs/architecture.md) — the code's shape, the next seams, the build order.

## Decisions, and why

One line each; the long version of every one of these is in [docs/decisions.md](docs/decisions.md).

**The camera starts on a second tap.** The brief says nothing is initialised on load, so that tap is
both the initialisation and the permission prompt.

**One RTMP connection for the whole broadcast.** Anything else makes the return a second publisher
on the same key, which Twitch displaces rather than resumes.

**The polite goodbye is `closeStream` and nothing else.** `FCUnpublish` and `deleteStream` apply
only to streams created with an `fcPublishName`, and this wrapper sets none.

**The restore waits for the suspend that is still running.** iOS freezes the app partway through
handing the devices back, so a fast return otherwise finds nothing to restore and the preview dies.

**The compositor starts before the devices, and the wait after it is an edge, not a level.** That
ordering is the freeze fix, and both halves are pinned by tests, because an ordering is the easiest
thing in the world to undo by accident.

**The resume closes the dead connection before it redials.** `RTMPConnection.connected` lies after a
suspension, and the alternative — teaching the controller to forgive `invalidState` — would drag one
wire protocol through the half of the app whose value is that it does not know RTMP exists.

**No `.suspended` state.** A sixth state would have leaked into every `isLive` and `isBusy` guard,
and no screen would render it differently.

**The restore placeholder shows no camera imagery at all.** Spinner, one line, black, and
specifically not *Turn on the camera*, which would invite a tap that fights what the app is doing.

**The duration continues instead of restarting.** After a reconnection or a background round trip
this is the same broadcast, so the panel shows its real age.

**Only `.background` tears the devices down.** `.inactive` also fires under the system permission
alert, where handing the devices back would fight the thing the user was just asked to allow.

**The event-reading task is started once and never cancelled.** Cancelling the consumer of an
`AsyncStream` finishes it permanently, and a reader started afterwards receives nothing at all.

**The mixer composites for the entire life of a capture.** Switching `videoMixerSettings.mode`
mid-flight rebuilds the video encoder and interrupts both pictures for about a second.

**The stream key is stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.** Nothing streams
while the device is locked, so this is the strictest keychain class that still works.

**Portrait only.** Rotating the preview and the outgoing picture together ends in a product decision
about what a live broadcast does mid-rotation, and portrait is the version that cannot be wrong.

**`BroadcastConfiguration.validate()` exists even though it can never fail today.** The moment there
is a settings screen, the Twitch limits it checks are what stop the app opening a broadcast the
server will drop.
