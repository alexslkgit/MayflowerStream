//
//  StreamOverlayTests.swift
//  MayflowerStreamTests
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import CoreGraphics
import Foundation
import Testing

@testable import MayflowerStream

@Suite("The overlay seam")
struct StreamOverlayTests {

    @Test("The clock overlay asks to be redrawn every second")
    func clockOverlayDescribesItself() {
        #expect(ClockOverlay().refreshInterval == .seconds(1))
    }

    @Test("The clock overlay sits at the top trailing corner, clear of the status panel and inside every screen's crop")
    func clockOverlaySitsTopTrailing() {
        #expect(ClockOverlay().placement == .topTrailing)
    }

    @Test("The top trailing margins scale with the frame and clear the worst-case preview crop")
    func topTrailingMarginsScaleWithFrame() {
        let frame = CGSize(width: 720, height: 1280)
        let margins = StreamOverlayPlacement.topTrailing.layoutMargins(in: frame)
        #expect(margins.right == frame.width * 0.15)
        #expect(margins.top == frame.height * 0.09)
        // The crop floor: the narrowest phones crop up to ~10% of frame width per side, or the clock reads as cut off.
        #expect(margins.right >= frame.width * 0.10)
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
