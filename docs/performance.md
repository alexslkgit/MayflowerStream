# Timings, reconnection and leaving the app

Everything here was measured on an iPhone 13 Pro Max, launched from the home screen rather than from
Xcode, for the reason set out in [running.md](running.md).

## How fast it is

| Tap | Milestone | Time |
|---|---|---:|
| Turn on the camera | permission answered | 27 ms |
| | video attached | 250 ms |
| | mixer running | 482 ms |
| | preview live | 510 ms |
| Record | RTMP connected | 408 ms |
| | publish accepted | 1245 ms |
| | panel says Online | 1258 ms |

Half a second to a picture, about 1.3 seconds to being on air. Most of that second is the RTMP
handshake, which is Twitch's to spend.

While the stream is live a capsule under the status panel shows the measured frame rate and the
measured outgoing data rate, refreshed once a second. The data rate is the whole stream on the wire,
audio and RTMP overhead included, which is why it reads a little above the configured 2.5 Mbps
rather than matching it. Tapping the status panel opens a sheet that lists every configured
parameter beside what the encoder reports it is actually using, read back out of
`RTMPStream.videoSettings` and `audioSettings`. When two numbers disagree, both are shown and the
row turns orange. That is my honest version of "guarantee the stream matches the configured
settings": if the encoder ever does something else, you see it instead of being reassured.

## When the connection drops

A connection that dies on its own is re-established without asking. Five attempts, with a doubling
wait in front of each one:

| Attempt | Waits before it | Elapsed since the drop |
|--------:|----------------:|-----------------------:|
| 1 | 1 s | 1 s |
| 2 | 2 s | 3 s |
| 3 | 4 s | 7 s |
| 4 | 8 s | 15 s |
| 5 | 16 s | 31 s |

The right column counts waiting only. On a dead network an attempt fails in well under a second, so
those numbers are close to what you actually see; on a live one an attempt either succeeds or fails
fast, which is the point of burning through the budget rather than sitting on it.

Those waits are for a network that is still gone. Once the device reports a usable path again, the
wait that is running is cancelled, and so is every wait after it for as long as the path stays up.
A fresh loss re-arms the ladder. Here is what that produces:

| Situation | What the app does | Back on air after |
|---|---|---|
| Wi-Fi blips for a second or two | ladder starts; the path returning cancels the running wait | ~1 s (a 750 ms settle, then the connect) |
| Airplane mode for half a minute | attempts fail fast, waits run in full while there is no path; the return cancels the current wait and all the ones behind it | ~1 s after the path is back |
| The path returns while an attempt is already in flight | nothing to cancel — see below | up to 15 s, then the next attempt fires with no wait in front of it |
| Network never comes back | five attempts, 31 s of waiting, then it stops lying to you | never; you get a card saying reconnection gave up, with Try again, camera still running behind it |
| Twitch rejects the stream key, or refuses the broadcast | not retried at all | n/a; retrying a rejected key only delays telling you the truth |

The 750 ms settle in row one is deliberate. A path the system reports as satisfied is not yet a path
that carries a connection: Wi-Fi is still associating, DNS is not answering, and an attempt fired on
that edge fails in under a second for a reason that has nothing to do with the server. The settle is
taken once per return of the path, so it does not creep back into a ladder whose waits were just
skipped.

The 15 s in row three is the one delay I cannot shorten. HaishinKit's connect sits on a hardcoded
15-second socket timer (`RTMPSocket.swift`), the call is not cancellable, and firing a second
`connect()` at the same `RTMPConnection` races two handshakes over one object, which corrupts it. So
an attempt that was already flying when the network came back has to finish dying first. That case
is where the whole skip-the-wait mechanism came from: on the device run that provoked it, the app
sat 22 seconds between "Reconnecting (4)" and "(5)", which decomposed into a full 8-second wait plus
about 14 seconds of an attempt hanging on that library timer. The waits are now skippable; the
timer is not.

While a wait is running the screen shows "Next attempt in N s", counting down, so a pause is
something you can watch rather than something that looks like a hang. And the duration keeps
counting through all of it. It is the length of the broadcast, not the length of the current TCP
connection.

## When you leave the app

The app does not broadcast in the background, because iOS takes the camera away and there is nothing
honest to do about that. What it does not do is hang up on Twitch.

On `.background` the camera, the microphone and the audio session go back to the system. The RTMP
connection, the stream and their status observers stay up behind the black screen. What stops is the
picture, not the session. Coming back re-attaches the devices to a pipeline that was never torn
down, and the mute state and the clock overlay come back with them if they were on.

| Away for | The RTMP session | What the return does | What you see |
|---|---|---|---|
| a trip to Control Centre | never closed | re-attach devices, ask the library if the publish is still up, go straight back to Online | spinner and "Bringing the camera back…" while the devices re-attach |
| a few seconds in another app | still open; nothing on the wire ended | same as above, no republish at all | same |
| long enough for iOS to suspend the process | dies with the socket | close the leftover connection, then the ladder redials over the same object; the first attempt publishes, in 1.1–1.6 s | "Picking the broadcast back up…", then Online; the Reconnecting card only if that first attempt fails |
| more than ~90 s | Twitch's hold has expired | the ladder still runs and still reconnects | a new stream on the channel, no matter what the client does |

Two numbers describe the same return and are both true: the publish is re-accepted in 1.1–1.6 s,
and the picture is live at about three seconds — the camera bring-up finishes after the dial does,
and [background-recovery.md](background-recovery.md) measures the picture, which is what you see.

That last row is worth being blunt about: the app's duration keeps counting from the original start
in every one of these cases, so after a long gap the panel can say 4:12 while Twitch's dashboard
says 0:06. The panel is describing this broadcast. Twitch is describing what it decided to keep.

Why the short cases survive at all is the one-connection rule on the README's front page; why the
long ones no longer freeze the picture is [background-recovery.md](background-recovery.md).

An explicit Stop, or leaving the broadcast screen, is a different thing entirely and does say
goodbye. Those exits are not coming back.
