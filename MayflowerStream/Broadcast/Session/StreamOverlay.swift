//
//  StreamOverlay.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 13.08.2026.
//

import CoreGraphics
import Foundation

/// Says *what* to show and *where*; the session owns the drawing (compositing belongs to the
/// streaming library), and the same composited frame feeds the encoder and the preview.
/// `text(at:)` is the only content this protocol has and the session hard-wires a
/// `TextScreenObject` for it — an image overlay would need the protocol extended first, even
/// though HaishinKit's `ImageScreenObject` already exists for the rendering side.
protocol StreamOverlay: Sendable {
    var placement: StreamOverlayPlacement { get }
    /// `nil` for something that never changes.
    var refreshInterval: Duration? { get }
    func text(at date: Date) -> String
}

/// `topTrailing` pins to the right edge with margins computed from frame size, avoiding both the
/// aspect-fill crop and the status panel at the top. Adding a case here forces two exhaustive
/// switches in `HaishinKitStreamingSession`, so a placement can't be added and left undrawn.
enum StreamOverlayPlacement: Equatable, Sendable {
    case topTrailing
}

extension StreamOverlayPlacement {
    /// 15% right margin clears the worst aspect-fill crop (~10% per side on the narrowest phones);
    /// 9% top margin clears the status panel drawn over the first ~6.5% of the preview.
    func layoutMargins(in frameSize: CGSize) -> (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        switch self {
        case .topTrailing:
            return (top: frameSize.height * 0.09, left: 24, bottom: 24, right: frameSize.width * 0.15)
        }
    }
}

struct ClockOverlay: StreamOverlay {
    var placement: StreamOverlayPlacement = .topTrailing
    var refreshInterval: Duration? = .seconds(1)

    func text(at date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
