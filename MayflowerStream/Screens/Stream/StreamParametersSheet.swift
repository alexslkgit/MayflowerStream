//
//  StreamParametersSheet.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import SwiftUI

private enum Strings {
    static let navigationTitle = "Stream parameters"
    static let broadcastSection = "Broadcast"
    static let status = "Status"
    static let duration = "Duration"
    static let dataRate = "Data rate"
    static let videoSection = "Video"
    static let codec = "Codec"
    static let resolution = "Resolution"
    static let bitrate = "Bitrate"
    static let frameRate = "Frame rate"
    static let keyframeInterval = "Keyframe interval"
    static let audioSection = "Audio"
    static let matches = "The outgoing stream matches these settings."
    static let mismatch = "The encoder is not using every setting as configured. The rows in orange show what it reported instead."
    static let measuredFooter = "Frame rate and data rate are measured: the data rate is what actually left the device over the last second, audio and protocol overhead included, which is why it reads a little above the configured bitrates. Everything else is read back from the encoder."
    static let noParameters = "No stream parameters yet."
}

struct StreamParametersSheet: View {
    let state: BroadcastState
    let duration: String
    let statistics: StreamStatistics?

    var body: some View {
        NavigationStack {
            List {
                Section(Strings.broadcastSection) {
                    row(Strings.status, state.label)
                    row(Strings.duration, duration)
                    if let statistics {
                        // The number the on-air HUD shows, next to the two bitrates it should be
                        // compared against.
                        measuredRow(
                            Strings.dataRate,
                            kilobits(statistics.configured.videoBitRate + statistics.configured.audioBitRate),
                            measured: statistics.currentBytesPerSecond.map { kilobits($0 * 8) }
                        )
                    }
                }

                if let statistics {
                    Section(Strings.videoSection) {
                        row(Strings.codec, BroadcastConfiguration.videoCodec, applied: statistics.appliedVideoCodec)
                        row(
                            Strings.resolution,
                            format(statistics.configured.videoSize),
                            applied: statistics.appliedVideoSize.map(format)
                        )
                        row(
                            Strings.bitrate,
                            kilobits(statistics.configured.videoBitRate),
                            applied: statistics.appliedVideoBitRate.map(kilobits)
                        )
                        measuredRow(Strings.frameRate, "\(Int(statistics.configured.frameRate)) fps",
                                    measured: statistics.currentFrameRate.map { "\($0) fps" })
                        row(Strings.keyframeInterval, "\(Int(statistics.configured.keyFrameIntervalSeconds)) s")
                    }

                    Section(Strings.audioSection) {
                        row(Strings.codec, BroadcastConfiguration.audioCodec, applied: statistics.appliedAudioCodec)
                        row(
                            Strings.bitrate,
                            kilobits(statistics.configured.audioBitRate),
                            applied: statistics.appliedAudioBitRate.map(kilobits)
                        )
                    }

                    Section {
                        Label {
                            Text(statistics.matchesConfiguration ? Strings.matches : Strings.mismatch)
                        } icon: {
                            Image(systemName: statistics.matchesConfiguration
                                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(statistics.matchesConfiguration ? .green : .orange)
                        }
                        .font(.footnote)
                    } footer: {
                        Text(Strings.measuredFooter)
                    }
                } else {
                    Section {
                        Text(Strings.noParameters)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(Strings.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

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

    // Measured values are never flagged, so they cannot contradict the summary line above: a
    // difference here is what the camera and network managed, not the encoder disagreeing with
    // its settings.
    @ViewBuilder
    private func measuredRow(_ name: String, _ configured: String, measured: String?) -> some View {
        LabeledContent(name) {
            if let measured, measured != configured {
                Text("\(configured), \(measured) now")
                    .foregroundStyle(.secondary)
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
            currentFrameRate: 30,
            currentBytesPerSecond: 328_000
        )
    )
}
