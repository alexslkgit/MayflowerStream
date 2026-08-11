import SwiftUI

/// The bottom sheet behind the information panel, reachable only while the broadcast is Online.
///
/// It exists to answer one question the task asks explicitly: is the stream actually going out
/// with the settings it was configured with? So every row shows what was asked for, and shows what
/// the encoder reported back next to it whenever the two differ.
struct StreamParametersSheet: View {
    let state: BroadcastState
    let duration: String
    let statistics: StreamStatistics?

    var body: some View {
        NavigationStack {
            List {
                Section("Broadcast") {
                    row("Status", state.label)
                    row("Duration", duration)
                }

                if let statistics {
                    Section("Video") {
                        row("Codec", BroadcastConfiguration.videoCodec, applied: statistics.appliedVideoCodec)
                        row(
                            "Resolution",
                            format(statistics.configured.videoSize),
                            applied: statistics.appliedVideoSize.map(format)
                        )
                        row(
                            "Bitrate",
                            kilobits(statistics.configured.videoBitRate),
                            applied: statistics.appliedVideoBitRate.map(kilobits)
                        )
                        row("Frame rate", "\(Int(statistics.configured.frameRate)) fps",
                            applied: statistics.currentFrameRate.map { "\($0) fps" })
                        row("Keyframe interval", "\(Int(statistics.configured.keyFrameIntervalSeconds)) s")
                    }

                    Section("Audio") {
                        row("Codec", BroadcastConfiguration.audioCodec, applied: statistics.appliedAudioCodec)
                        row(
                            "Bitrate",
                            kilobits(statistics.configured.audioBitRate),
                            applied: statistics.appliedAudioBitRate.map(kilobits)
                        )
                    }

                    Section {
                        Label {
                            Text(statistics.matchesConfiguration
                                 ? "The outgoing stream matches these settings."
                                 : "The encoder is not using every setting as configured. The values in grey are what it reported.")
                        } icon: {
                            Image(systemName: statistics.matchesConfiguration
                                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(statistics.matchesConfiguration ? .green : .orange)
                        }
                        .font(.footnote)
                    } footer: {
                        Text("Frame rate is measured. Everything else is read back from the encoder.")
                    }
                } else {
                    Section {
                        Text("No stream parameters yet.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Stream parameters")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    /// One row. When the encoder reported something different, both values are shown rather than
    /// the app quietly picking whichever one looks better.
    @ViewBuilder
    private func row(_ name: String, _ configured: String, applied: String? = nil) -> some View {
        LabeledContent(name) {
            if let applied, applied != configured {
                Text("\(configured) → \(applied)")
                    .foregroundStyle(.orange)
            } else {
                Text(configured)
            }
        }
        .monospacedDigit()
    }

    private func format(_ size: CGSize) -> String {
        "\(Int(size.width))×\(Int(size.height))"
    }

    private func kilobits(_ bitsPerSecond: Int) -> String {
        "\(bitsPerSecond / 1000) kbps"
    }
}

#Preview {
    StreamParametersSheet(
        state: .online,
        duration: "02:14",
        statistics: StreamStatistics(
            configured: .default,
            appliedVideoSize: CGSize(width: 720, height: 1280),
            appliedVideoBitRate: 2_500_000,
            appliedVideoCodec: "H.264",
            appliedAudioBitRate: 128_000,
            appliedAudioCodec: "AAC",
            currentFrameRate: 30
        )
    )
}
