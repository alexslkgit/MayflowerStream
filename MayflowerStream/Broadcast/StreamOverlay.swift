//
//  StreamOverlay.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import Foundation

/// Something drawn on top of the picture that goes out.
///
/// An overlay says *what* to show and *where*; the session owns the drawing, because compositing
/// is the one part of it that belongs to the streaming library. The same composited frame feeds
/// the encoder and the on-screen preview, so what the user sees is what the viewers see.
///
/// A richer *text* overlay — a longer caption, a live viewer count, a lower third — is the same
/// protocol with a different implementation; only `HaishinKitStreamingSession` needs to learn how to
/// draw a new kind, and nothing above it changes. An overlay whose content is an image is not a
/// drop-in: `text(at:)` is the only content this protocol has and the session hard-wires a
/// `TextScreenObject` to draw it, so an image overlay would need the protocol to grow an
/// image-content requirement first. HaishinKit already has `ImageScreenObject` for the rendering
/// side — it is the boundary here, not the drawing, that is missing.
protocol StreamOverlay: Sendable {
    var placement: StreamOverlayPlacement { get }
    /// `nil` for something that never changes.
    var refreshInterval: Duration? { get }
    func text(at date: Date) -> String
}

/// Both cases are centred horizontally. An overlay pinned to a side edge sits a fixed margin from
/// it in the composited frame, and that is not the margin the broadcaster sees: the preview
/// aspect-fills the frame into the device's screen and crops the sides away, which is how the clock
/// came to hang off the right-hand edge on a phone. Centred, it cannot drift off any screen at any
/// resolution.
///
/// Adding a placement is an enum case plus two exhaustive switches in
/// `HaishinKitStreamingSession`, so one cannot be offered here and then forgotten about at the
/// drawing end.
enum StreamOverlayPlacement: Equatable, Sendable {
    case topCenter
    case bottomCenter
}

/// The worked example: the time of day, burned into the broadcast.
struct ClockOverlay: StreamOverlay {
    var placement: StreamOverlayPlacement = .topCenter
    var refreshInterval: Duration? = .seconds(1)

    func text(at date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
