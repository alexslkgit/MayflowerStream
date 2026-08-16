# Memory, leaks and responsiveness

What I actually measured, on an iPhone 13 Pro Max, and what I am prepared to claim from it. The
short version: no leaks in app code, a flat live-object count, a footprint that sits around 90–100 MB
while broadcasting, and three sub-second main-thread stalls I know about and did not fix.

## Method

The same scripted scenario was recorded twice, back to back, in one sitting: launch, turn on the
camera, go on air, then three background cycles of roughly 11 s, 44 s and 89–111 s with a return and
a settle after each, then stop.

- **Light recording** — Time Profiler template, plus Hangs at a 100 ms threshold and the app's own
  `os_log` marks. This is the run the millisecond timings come from.
- **Heavy recording** — Leaks template with Allocations, same extras. This is the run the leak
  verdict comes from.

Two recordings rather than one because Allocations instrumentation perturbs exactly the arithmetic
that the freeze work depends on (see [background-recovery.md](background-recovery.md), where every
number is a difference between two timestamps a few milliseconds apart). One combined run would have
given a worse answer to both questions for the sake of saving three minutes. Both were driven
headless with `xctrace` so the phone did nothing but sit there.

## Leaks

**Zero leaked objects in app code.** The leak scan over the heavy pass lists nine objects totalling
1,904 bytes, and every one of them is allocated inside CoreVideo:

| Count | Responsible frame | Bytes |
|---|---|---:|
| 2 | `CVPixelBufferPool::initWithOptions` | 144 |
| 2 | `CVObject::alloc` (`CVPixelBufferPool`, `CVLocklessBunchPair`) | 512 |
| 1 | `CVPixelBufferPool::CVPixelBufferPool` | 256 |
| 4 | `CVAtomicBunchNew` / `CVAtomicBunchIncreaseSizeAndReserveElement` | 992 |

That is the pixel-buffer pool's one-time setup, a known framework artifact, allocated once and not
proportional to anything the app does. Nothing in the list is reachable from an app type, and the
total does not grow with the number of background cycles.

## Footprint

`phys_footprint` was logged once a second throughout both passes.

- Under the light template it **plateaued at 89–101 MB** across all three background cycles, with no
  upward trend from cycle to cycle.
- Under the Leaks/Allocations template it **climbed from 93 MB to 136 MB** over the pass.

I am reporting both because reporting only the flattering one would be dishonest. My reading is that
the climb is the recorder's own in-process buffering — Allocations in deferred mode keeps its event
stream inside the target process — and not the app. Two independent facts support that: the leak
list above is empty of app objects, and the live-instance counters below are flat across the same
heavy pass. If the app were accumulating 40 MB, something would have to be holding it, and nothing
is. I have not proven it to the standard the freeze work was proven to, and I would want a device
build with the recorder detached to settle it properly.

Steady state while broadcasting is therefore about 90–100 MB, which is what the light pass shows.

## Live-instance counters

The scenario also logged, once per second, how many of the app's long-lived objects existed:

```
controllers=1  sessions=1  previews=0↔1
```

— in every heartbeat of every cycle of both passes. The preview count moves between 0 and 1 because
the preview view genuinely goes away while the app is backgrounded and comes back on return.

These counters exist because they used to read differently. Before this pass there were **three**
controllers and three sessions alive at once, visible in the trace as three heartbeats a second: the
broadcast screen was constructing its controller and session inside a SwiftUI view struct's
initialiser, which runs on every view-struct construction, and the discarded copies were retained
forever by their own event-reading task and heartbeat. Separately, the preview view list grew by one
per foreground return — one, then two, then three Metal views after two round trips — because
attaching appended and releasing never pruned. Both are fixed and both are pinned by tests; see
[test-report.md](test-report.md).

## Main-thread responsiveness

The Hangs instrument, at a 100 ms threshold, found three stalls in the light pass and nothing else:

| When | Duration | Classified as |
|---|---:|---|
| Publish start | 919 ms | Hang |
| First foreground return | 271 ms | Microhang |
| Second foreground return | 286 ms | Microhang |

All three sit at transition moments, all three are sub-second, and none of them is the freeze this
work was about — that one was minutes long in the worst case and is gone. I have left them as known
items rather than chasing them inside a change whose job was the freeze: fixing them means moving
work off the main thread at exactly the points where the state machine is at its most delicate, and
that is a separate piece of work with its own tests.

The heavy pass's hang table could not be extracted — two export attempts against that trace returned
nothing usable — so the three numbers above are from the light pass only, and I have not
cross-checked them against a second recording.

## Sanitizers and the debug allocator

The full 186-test suite was run three more times, each in a clean derived-data directory:

| Run | Result |
|---|---|
| AddressSanitizer | TEST SUCCEEDED, zero reports |
| ThreadSanitizer | TEST SUCCEEDED, zero reports |
| MallocScribble + MallocGuardEdges | TEST SUCCEEDED, zero reports |

A clean sanitizer run is worth nothing if the runtime was never linked, so I checked rather than
assumed: `libclang_rt.asan` is present in both the app dylib and the test binary, and
`libclang_rt.tsan` in the app binary. The builds are genuinely instrumented.

UndefinedBehaviorSanitizer and the static analyser were skipped deliberately: there is no C, Objective-C
or C++ anywhere in this project or in the HaishinKit checkout it builds against, so neither has
anything to look at.

The honest limit on all of this: the suite runs on the simulator with no hardware, so the sanitizers
cover the state machine, the failure vocabulary and the pure logic, not the capture pipeline in
anger. The capture pipeline is what the two device recordings above are for.
