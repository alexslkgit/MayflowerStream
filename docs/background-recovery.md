# The freeze after a background trip

For a while this app had a bug I could not have guessed from the code. Leave it long enough for iOS
to suspend the process, come back, and the picture froze on one stale frame — preview and outgoing
stream together — for about as long as the app had been away. Then it healed on its own. Away for
twelve seconds, frozen for twelve. Away for a minute and a quarter, frozen for a minute and a
quarter. This document is how I found the mechanism, what I changed, and what the same scenario
measures now.

The short version: HaishinKit 2.2.5's compositor latches its presentation timestamp into the future
when the camera is attached before the display link has ticked, and every live frame is dropped in
silence until the wall clock catches up to the latch. Bringing the compositor up first, before the
devices, is the whole fix.

## What it looked like

The status panel kept counting and stayed Online. The mute button still responded. The HUD read
`0 fps · 2 kbit/s`. Everything in the app that reports on itself said it was healthy, and the
picture was dead. On Twitch's side the player showed black with a spinner: the server was holding
the session open and no video frames were arriving.

That combination is what made it interesting rather than obvious. A frozen *preview* is a local
fact — nothing about a network can explain it — so the socket was never a suspect for long.

## How I measured it

I could not reproduce it under Xcode, for the reason the README opens with, so I instrumented
instead. One diagnostic build carried 174 temporary `os_log` marks: every state assignment funnelled
through a single setter, a 1 Hz heartbeat with state, flags, fps and byte counts, app lifecycle,
capture and audio-session notifications, raw RTMP status codes, and the two probes that were the
point of the exercise — one on the compositor's frame callback logging presentation timestamp, wall
clock and their delta per composited frame, and one counting raw camera buffers reaching the mixer.

Two things cost me a run to learn. `.info` marks live only in the memory ring and were evicted
before I could collect them, so diagnostics have to be `.notice`; and launching over the cable with
`--console` relays stdout only, not `os_log`, so the live console cannot stand in for `sudo log
collect` and its archive. With the archive in hand the arithmetic closes to about 26 ms.

That instrumentation is all out of the code now. What survives it is the numbers below and the tests
in [test-report.md](test-report.md).

## The mechanism

Two episodes in one run, both matching:

- Background 11.56 s → frozen 11.87 s. Background 73.47 s → frozen 74.34 s.
- In each, exactly **one** composited frame came out at the resume, stamped +11.78 s and +74.26 s
  into the future respectively, and then nothing at all until the wall clock passed that stamp. The
  recovery margins were +0.026 s and +0.017 s — the clock catching the latch, not a timeout expiring.
- The camera was innocent throughout: raw input ran at 30–31 fps continuously through both freezes.

The chain, with the library's line numbers, since this is a claim about someone else's code:
`releaseDevices` stops the mixer, and `Screen.reset()` (Screen.swift:230-236) clears neither
`targetTimestamp` nor `videoCaptureLatency` nor `presentationTimeStamp`. On resume the old order
attached the devices before starting the mixer, so the first camera buffer met a `targetTimestamp`
left over from before the suspension: `setVideoCaptureLatency` (Screen.swift:221-227) computed a
latency of roughly −D, where D is the background duration. The next display-link tick therefore
stamped its frame `now + D` and latched that as the high-water mark (Screen.swift:177-181), after
which the guard on that mark swallowed every frame for D seconds. `VideoCodec` keeps a second
high-water on the same value, which is why the wire went to 0 fps too — episode two sent audio only,
about 16 kB/s, for 67 seconds.

## The fix

Capture bring-up is now ordered, in both cold start and resume, behind a small `CaptureBringUp`
protocol with one static `bringUpCapture` that runs the steps:

1. **Start the compositor first.** The display link then ticks on an empty screen, and its `defer`
   refreshes `targetTimestamp` while re-latching `presentationTimeStamp` at the present. The stale
   pair is gone before any camera buffer can be measured against it.
2. **Wait for one composited frame**, bounded at 200 ms, falling through on a miss rather than
   failing. In the two instrumented passes this wait always saw its frame, and waited single- to
   double-digit milliseconds; it has never hit the bound.
3. **Attach the devices.**
4. **Wait for the first real camera buffer** — and this one had to change too. The old wait keyed on
   `videoInputFormats`, which is a *level*: it stays set across a suspension, so after the first
   resume the wait no-oped and returned immediately. In episode two the encoder was attached 5 ms
   *before* the first camera buffer arrived. It is now an edge, a latch that arms and fires once on
   an actual buffer.
5. **Attach the stream output.**

The ordering is not a comment; it is pinned by a test that records the calls and fails printing the
wrong order, and the arithmetic above is pinned by a model of the library's clock. Both are
described in [test-report.md](test-report.md).

| Away for | Before | After, pass A | After, pass B |
|---|---|---|---|
| ~11 s | freeze ≈ background | 3.06 s | 3.08 s |
| ~44 s | freeze ≈ background | 3.03 s | ~3.6–4.7 s |
| ~89–111 s | freeze ≈ background | 3.76 s | 3.14 s |

Two full scripted passes on the same iPhone 13 Pro Max; "after" is time from the return to a live
30 fps picture. The point is not that three seconds is fast — it is that the number stopped tracking
the background duration at all.

## The reconnect half

Sitting on top of every long freeze was a second cost. After a real suspension the socket is dead,
but `RTMPConnection.connected` still reads `true`; only `readyState` told the truth. The library's
dial guard (RTMPConnection.swift:288-290, `guard !connected`) therefore rejected the ladder's first
attempt with `invalidState` in the same millisecond it was made, and the app spent that rung plus
its backoff learning nothing. The two measured recoveries took 14.0 s and 7.4 s end to end, of which
the wasted rung accounted for roughly 2–6.5 s.

The resume path now closes the leftover connection — teardown, and wait for it — before the first
dial, in the branch where the publish is already known to be gone. First attempt now publishes in
1.1–1.6 s every time a reconnect is needed at all. Backgrounds under about fifteen seconds do not
reconnect: the publish survives them, which is what the one-connection-per-broadcast decision in the
README buys.

## The automated pass

Because all of the above is device-only, I also ran the scenario over the cable without touching the
phone: launch, broadcast, background for 70 seconds, return, then read the app's own fps capsule
until it shows a live rate. That pass measures **3.39 s**; the identical scenario froze for over 70
seconds before the fix. A blunt instrument next to the log arithmetic, but the one piece of this
that runs unattended.

## What I did not fix

If the app is suspended *during* an already-frozen episode, the latched future timestamp survives
into the next resume, and the reorder cannot clear a latch that already exists — only a fork of the
library could. I left it: the reorder is what stops such an episode from starting, so reaching that
state now requires the bug to have already happened. Three sub-second main-thread stalls also remain,
around publish start and the first two returns; they are measured, listed and deliberately left alone
in [memory-and-performance.md](memory-and-performance.md).
