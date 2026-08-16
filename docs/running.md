# Running it, and the Twitch side of it

Open `MayflowerStream.xcodeproj`, run the `MayflowerStream` scheme, pick your own development team
under Signing & Capabilities. The project pins no team. The simulator has no camera and no
microphone, so it is good for the configuration screen, the state machine and the whole test suite,
and useless for anything you can see.

The test suite:

```
xcodebuild -project MayflowerStream.xcodeproj -scheme MayflowerStream \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Install once, then leave the debugger behind

The RTMP pipeline is soft real time. An attached debugger is not. Swift throw interception, the
Main Thread Checker, Metal API validation and unoptimised package builds can each stall the main
thread for seconds, and they pick their moment: usually the exact moment the app is recovering a
dropped connection. What you see is a frozen UI and a stalled video pipeline that never happen
untethered. HaishinKit's maintainer has closed several identical freeze reports the same way
(upstream #1574, #1722, both reproducible only under Xcode).

So: install once, stop the debug session, launch the app from the home screen. Every number in
[performance.md](performance.md) and [background-recovery.md](background-recovery.md) was measured
that way.

## The console noise you will see if you run it tethered anyway

Most of what fills the Xcode console during a broadcast was not printed by this app. CoreMedia and
the audio stack narrate themselves for any app that runs a camera into an RTMP encoder — the
recurring `(Fig) err=-12710` and `err=-19224`, and `CMBufferQueue err=-12764` — and none of it
corresponds to anything failing here. It is the frameworks', not the app's.

What the app does control is its dependency: `LBLogger.with(kHaishinKitIdentifier).level = .warn` at
launch, because HaishinKit narrates every format negotiation at `.info` and would otherwise bury
the one log worth reading. What is left in the console from this project is the app's own.

## Getting a stream key

The ingest address is already filled in (`rtmp://euw10.contribute.live-video.net/app`, Twitch's Irish
ingest); the alternatives are at [ingest.twitch.tv](https://ingest.twitch.tv/ingests). The key comes
from **Twitch → Creator Dashboard → Settings → Stream**. If you paste a full ingest URL with the key
still glued on the end and leave the key field empty, the app splits it into its two halves rather
than rejecting it.

## Disconnect Protection

Continuity across an interruption is not a client-side property. It requires **Disconnect
Protection** to be enabled on the channel, under Creator Dashboard → Settings → Stream. With it off,
Twitch holds nothing across any interruption, and every blip is a new stream regardless of what the
app, OBS, or anything else does. It took me two device passes and one confidently wrong root-cause
theory before I thought to look at that toggle, which is why it is on the README's front page.

## Two more things for anyone testing this

- The channel page's live indicator lags reality badly. In my runs it took roughly 50 seconds after
  the publish was accepted before the site admitted the stream existed. The Stream Manager updates
  much faster, so watch that instead.
- A wrong stream key does not come back as `NetStream.Publish.BadName`. Twitch completes the TCP
  connect and the RTMP handshake, then hangs up about 1.3 seconds later without saying why. The app
  treats a close inside the publish handshake as a rejected key, because "check your key" costs a
  retry, while "check your internet" on a genuinely bad key loses the broadcast entirely.
