# Decisions, and why — the long version

The README carries the same list in one-line form, in this order. This is the reasoning behind each
one, including the alternatives I rejected.

**The camera starts on a second tap.** Page 3 of the brief says the main screen shows a preview;
page 4 says nothing should be initialised on load and permissions should be requested only when
needed. The strict reading wins: the screen opens with a *Turn on the camera* button, and that tap
is both the initialisation and the permission prompt. It also keeps `RTMPStream.init` out of a
SwiftUI view evaluation, where it would leave a live object behind on every re-evaluation.

**One RTMP connection for the whole broadcast.** Anything else makes the return a second publisher
on the same key, which Twitch treats as a displacement rather than a reconnect. Twitch accepts one
live publisher per stream key, and a session displaced by its own replacement is not a drop the
server holds open: its disconnect protection never engages, and you get a new stream with the uptime
back at zero after a three-second trip to the home screen. This cost me a device pass to find.
Keeping the one connection means the server sees no publisher change at all: the video stops
arriving for as long as the app is away, then continues in the same stream and the same VOD. It is
the single most consequential decision in the app.

**The polite goodbye is `closeStream` and nothing else.** `FCUnpublish` and `deleteStream` are sent
only for streams created with an `fcPublishName`, and this wrapper sets none, so claiming otherwise
in a code comment would have been a lie waiting to be found.

**The restore waits for the suspend that is still running.** Handing the devices back is not
instant, and iOS freezes the app partway through it, so a quick return routinely lands before the
suspend has finished writing down what it is supposed to restore. Without that wait, coming back
fast finds nothing to restore and leaves a dead preview. This one took a device pass to see, because
it never reproduces if you background the app slowly.

**The compositor starts before the devices, and the wait after it is an edge, not a level.**
HaishinKit's `Screen` keeps a high-water mark on the presentation timestamp and measures capture
latency against the display link's last target, and `reset()` clears neither, so attaching a camera
to a mixer that has not ticked since the suspension stamps one frame a whole background duration
into the future and drops everything behind it. Starting the mixer first lets a tick land on an
empty screen and re-latch both fields at the present. The wait for the first camera buffer that
follows had to change with it: it used to read `videoInputFormats`, a level that stays set across a
suspend, so from the second resume onward it returned instantly and waited for nothing. It is a
latch armed on an actual buffer now. Both halves are pinned by tests, because an ordering is the
easiest thing in the world to undo by accident while moving two lines around. The whole hunt is in
[background-recovery.md](background-recovery.md).

**The resume closes the dead connection before it redials.** After a suspension
`RTMPConnection.connected` still reads true although the socket is long gone — only `readyState` was
honest — so the library's own dial guard rejected the ladder's first attempt with `invalidState` in
the same millisecond, and every recovery paid a rung and its backoff for nothing. The alternative
was to stop counting that failure as an attempt, and I rejected it: `invalidState` is a
transport-specific condition, and teaching the controller about it would drag a detail of one wire
protocol through six exhaustive switches and the ladder itself, in the half of the app whose whole
value is that it does not know RTMP exists. Closing the leftover is two lines on the branch where the
publish is already confirmed gone, and the adapter's `stopPublishing` is the only thing that knows
what closing means. The one-connection rule above is untouched.

**No `.suspended` state.** A broadcast that is backgrounded with its connection alive is `.offline`
plus an `isRestoring` flag. A sixth state would have leaked into every `isLive` and `isBusy` guard
in the app, and there is no screen that would render it differently.

**The restore placeholder shows no camera imagery at all.** Spinner, one line, black. The last frame
is stale by then and every control belongs to a pipeline being rebuilt. It specifically does not
show *Turn on the camera*: the camera really is off for those few hundred milliseconds, and offering
a button for something the app is already doing invites a tap that fights it.

**The duration continues instead of restarting.** After a reconnection or a background round trip
this is the same broadcast, so the panel shows its real age. The clock is put back before the
ladder's first attempt rather than when the stream goes Online again, otherwise it counts up from
zero and then jumps.

**Only `.background` tears the devices down.** `.inactive` also fires while the system permission
alert is on screen, and handing the devices back there would fight the exact thing the user was
just asked to allow.

**The event-reading task is started once and never cancelled.** Cancelling the consumer of an
`AsyncStream` finishes that stream permanently, and a reader started afterwards receives nothing at
all. An app that got this wrong would publish frames while the screen said Connecting for ever.

**The mixer composites for the entire life of a capture.** Setting `videoMixerSettings.mode` to
`.offscreen` mid-flight rebuilds the video encoder (the offscreen pool is 32ARGB, the camera output
is 420v) and steps timestamps backward across clock domains, interrupting the preview and the
outgoing stream for about a second. So the mode is entered once, before `startRunning()`, and
toggling the clock overlay is a constant-time add or remove of one screen object.

**The stream key is stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.** Nothing streams
while the device is locked, so this is the strictest keychain class that still works, and it keeps
the key out of an unencrypted backup and off every other device.

**Portrait only.** The brief allows it, and the hard part of rotation is not layout: the preview and
the outgoing picture have to rotate together, which means driving `videoOrientation` from the
interface orientation, swapping the configured `videoSize`, re-applying the encoder settings, and
then deciding what a live broadcast does mid-rotation. Twitch accepts a mid-stream resolution
change; players handle it badly. That is a product decision, and locking to portrait is the version
that cannot be wrong.

**`BroadcastConfiguration.validate()` exists even though it can never fail today.** The quality
settings are a constant and there is no settings screen. The moment there is one, the Twitch limits
it checks are what stop the app from opening a broadcast the server will drop, and it fails with a
sentence the user can act on instead of an error from inside the encoder. It is tested now, so it is
trustworthy on the day something calls it in anger.
