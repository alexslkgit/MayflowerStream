//
//  StreamOverlayTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import Foundation
import Testing

@testable import MayflowerStream

@Suite("The overlay seam")
struct StreamOverlayTests {

    @Test("The clock overlay asks to be redrawn every second")
    func clockOverlayDescribesItself() {
        #expect(ClockOverlay().refreshInterval == .seconds(1))
    }

    @Test("The clock overlay sits centred, where no screen can cut it off")
    func clockOverlayIsCentred() {
        // A caption pinned to a side edge sits a fixed margin from it in the composited frame, and
        // that is not what the broadcaster sees: the preview aspect-fills the frame into the
        // device's screen and crops the sides, which is how the clock came to hang off the
        // right-hand edge on a phone. Centred, it is laid out from the frame's width alone.
        #expect(ClockOverlay().placement == .topCenter)
    }

    @Test("The clock overlay shows a time, and a different one a minute later")
    func clockOverlayShowsTheTime() {
        let overlay = ClockOverlay()
        let noon = Date(timeIntervalSince1970: 1_770_000_000)

        let atNoon = overlay.text(at: noon)
        #expect(!atNoon.isEmpty)
        #expect(atNoon.contains(":"), "a clock without a colon is not a clock: \(atNoon)")
        #expect(overlay.text(at: noon.addingTimeInterval(61)) != atNoon)
    }
}
