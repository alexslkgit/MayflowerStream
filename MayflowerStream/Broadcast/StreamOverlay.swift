//
//  StreamOverlay.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import Foundation

/// Something drawn on top of the picture that goes out.
///
/// This is the extensibility the task asks about, expressed as a type rather than as a promise in a
/// comment. An overlay says *what* to show and *where*; the session owns the drawing, because
/// compositing is the one part of it that belongs to the streaming library. The same composited
/// frame feeds the encoder and the on-screen preview, so what the user sees is what the viewers
/// see.
///
/// A richer overlay — an image, a logo, a live viewer count — is the same protocol with a different
/// implementation; only `HaishinKitStreamingSession` needs to learn how to draw a new kind, and
/// nothing above it changes.
protocol StreamOverlay: Sendable {
    /// Which corner of the picture it sits in.
    var placement: StreamOverlayPlacement { get }
    /// How often it should be redrawn. `nil` for something that never changes.
    var refreshInterval: Duration? { get }
    /// What to show at this moment.
    func text(at date: Date) -> String
}

enum StreamOverlayPlacement: Equatable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
}

/// The worked example: the time of day, burned into the broadcast, refreshed every second.
///
/// It is off until the user turns it on. It exists to prove the seam carries a moving overlay all
/// the way to the encoder — which is the hard half, and the half a comment cannot demonstrate.
struct ClockOverlay: StreamOverlay {
    var placement: StreamOverlayPlacement = .topTrailing
    var refreshInterval: Duration? = .seconds(1)

    func text(at date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
