//
//  StreamStatusPanel.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import SwiftUI

/// The information panel: what the broadcast is doing, and for how long.
///
/// It is the only thing on this screen that answers "am I live?", so it never borrows confidence
/// from the preview underneath it. The dot is grey when nothing is going out, amber while the app
/// is working on it, red when live, and red-on-error only through the word Error.
struct StreamStatusPanel: View {
    let state: BroadcastState
    let duration: String
    /// Set only when tapping does something, so the panel does not pretend to be a button.
    let onTap: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)

            Text(title)
                .font(.subheadline.weight(.semibold))

            if showsDuration {
                Text(duration)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if onTap != nil {
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())

        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the stream parameters")
        } else {
            content
        }
    }

    private var title: String {
        if case .reconnecting(let attempt) = state {
            return "Reconnecting (\(attempt))"
        }
        return state.label
    }

    private var showsDuration: Bool {
        switch state {
        case .online, .reconnecting: true
        case .offline, .connecting, .failed: false
        }
    }

    private var dotColor: Color {
        switch state {
        case .offline: .secondary
        case .connecting, .reconnecting: .orange
        case .online: .red
        case .failed: .red
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        StreamStatusPanel(state: .offline, duration: "00:00", onTap: nil)
        StreamStatusPanel(state: .connecting, duration: "00:00", onTap: nil)
        StreamStatusPanel(state: .online, duration: "01:23", onTap: {})
        StreamStatusPanel(state: .reconnecting(attempt: 2), duration: "01:31", onTap: nil)
        StreamStatusPanel(state: .failed(.connectionLost), duration: "00:00", onTap: nil)
    }
    .padding()
    .background(.black)
}
