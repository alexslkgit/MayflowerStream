# Test report

**186 tests in 22 suites**, up from 167 in 16, all still running with no camera, no microphone and no
server. The nineteen new tests are almost entirely about the background-recovery work: the freeze,
the reconnect accounting, and the two object-lifetime bugs the same device trace exposed.

The discipline is the one described under **Tests** in the README, and I am not going to restate it
here beyond one example of what it costs: the one-connection change's first red run failed weakly,
on state, so the test was tightened until it failed on `publishStartCount` reaching 2, which is the
actual bug. What follows is what each new test pins and what it looked like when it was red, because
that is the part a reader cannot verify by running the suite once.

## The ordering contract

The freeze fix is an *order*, and an order is the easiest thing in the world to undo by accident six
months later while moving two lines around. So it is not a comment. Capture bring-up runs through a
`CaptureBringUp` protocol with five members — start the compositor, wait for a composited frame,
attach the devices, wait for the first camera buffer, attach the stream output — and one static
`bringUpCapture` that drives them. A recording implementation collects the calls, and the test
asserts the sequence.

Red evidence: run against the old bring-up, it fails printing the order it actually saw, devices
before compositor. It is a small test and it is the one I most expect to earn its keep.

## The compositor clock

`CompositorClockModelTests` is the interesting one. It reduces HaishinKit 2.2.5's `Screen` to the two
pieces of arithmetic that decide whether a composited frame is emitted or silently dropped — the
high-water latch on the presentation timestamp (Screen.swift:177-181) and the capture latency
measured against the display link's last `targetTimestamp` (Screen.swift:221-227) — and runs a frame
clock forward over them at 30 fps.

It is a model, not the library, because the real thing needs a display link, a camera and a pixel
buffer pool. That is a real limitation and it is why the suite holds *three* tests here rather than
one:

1. **Camera attached before the display link ticks** — the old order. Exactly one frame comes out,
   stamped a full sixty seconds into the future, and every frame in the two seconds that follow is
   dropped. That is the device signature from the trace, reproduced arithmetically.
2. **Display link ticks first** — the tick refreshes both stale fields at the present, the first
   frame is stamped now, nothing is dropped, the longest gap in the picture is under two frame
   intervals.
3. **The order `bringUpCapture` actually runs**, driven through the same simulated pipeline, measured
   on the same clock. This is the lock on my code, and it means something only because the first two
   tests establish that the model behaves like the library.

Tests 1 and 2 are deliberate **characterisations of someone else's arithmetic**. They do not test
this app at all. They exist so that the day HaishinKit is bumped past 2.2.5 — which the README
already flags as the upgrade path for an unrelated reason — either they still pass, in which case the
ordering fix is still necessary and still sufficient, or one of them goes red and the new `Screen`
source has to be read before anything ships. A silent behaviour change in that arithmetic is
precisely the failure this whole document exists to prevent, and without these two it would land as
a mystery freeze on a user's phone.

## The edge, not the level

The wait for the first camera buffer used to read `videoInputFormats`, which stays set across a
suspension, so from the second resume onward it returned immediately and waited for nothing. It is
now a latch that arms and fires once on an actual buffer.

A latch is easy to write in a way that passes for the wrong reason, so I proved this one by
mutation: with `arm()` emptied out, the test goes red; restored, green. That is the only evidence I
trust for a test whose subject is "did this actually wait".

## Instance lifetimes

Two tests came directly off the trace, and both reproduced a measured number before they went green.

- **One controller, one session.** The broadcast screen was building its controller and session in a
  view struct's initialiser, so every view-struct construction made another pair, and each discarded
  copy kept itself alive through its own event task. The device showed three heartbeats a second.
  The screen now stores the endpoint and opens on first use, and a property test pins that the
  opening happens once. I rejected moving construction into `.task` — it forces an optional through
  about thirty reads in the body — and holding it in the parent as `@State`, which has the same
  default-argument evaluation problem that caused the bug.
- **Preview views do not accumulate.** Attaching appended to a list that releasing never pruned, so
  the count went 1 → 2 → 3 over two foreground returns. The test reproduces exactly that growth
  against the old behaviour and requires it flat now. The list holds weak boxes and prunes rather
  than clearing on release: clearing would risk leaving a still-attached view permanently black,
  which is worse than the leak it fixes. One stale box can survive a cycle inside the mixer's own
  outputs array — bounded, and not the unbounded growth that was there before.

## Reconnect accounting

The fake gained one knob, `leavesTheConnectionOpenAfterTheDrop`, which models the state the device
actually reported after a suspension: the publish is gone but the connection still calls itself
connected. With that knob on, the test requires the ladder's first attempt to publish rather than
burning a rung, which is what the leftover-connection close in the resume path now guarantees. The
decision to close rather than to stop counting the attempt is in the README.

The related read — whether the server is still holding the publish — was extracted into one static
predicate over connection state and ready state, and proven by mutation too: reduce it to the
connected flag alone, the flag the device lied with, and the test goes red.

## What the suite still cannot see

Unchanged from the README's own boundary, and worth restating with the new work in it.
`HaishinKitStreamingSession` needs a camera and a real server. The contract it has to honour — that
a failed `startPublishing` leaves nothing open, so the next attempt can succeed — is written on the
protocol and pinned by the fake, but a regression inside the real adapter would not turn the suite
red. The ordering contract is pinned, the clock arithmetic is pinned, the latch is pinned — but that
the real `MediaMixer` behaves like the model, that a real camera delivers its first buffer where the
latch is listening, and that the whole thing composes into a live picture in three seconds, are
device facts. They were measured on a device, twice, and the numbers are in
[background-recovery.md](background-recovery.md); one cut-down version of the scenario runs
unattended over the cable and gives 3.39 s to a live frame rate.

The suite was also run in full under AddressSanitizer, ThreadSanitizer and a debug allocator, all
clean, with the sanitizer runtimes checked to be genuinely linked. That matrix is in
[memory-and-performance.md](memory-and-performance.md).
