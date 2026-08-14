//
//  StreamConfigurationView.swift
//  MayflowerStream
//
//  Created by Slobodianiuk Oleksandr on 11.08.2026.
//

import SwiftUI

private enum Strings {
    static let navigationTitle = "Stream setup"
    static let ingestPlaceholder = "rtmp://…"
    static let serverHeader = "Server"
    static let serverFooter = "Twitch lists its ingest servers at ingest.twitch.tv. The one filled in is the closest European server."
    static let streamKeyPlaceholder = "live_…"
    static let showStreamKey = "Show stream key"
    static let streamKeyHeader = "Stream key"
    static let streamKeyFooter = "On Twitch: Creator Dashboard → Settings → Stream. The key is stored in this device's keychain, not in plain text."
    static let saveAndContinue = "Save and continue"
}

struct StreamConfigurationView: View {
    @State private var model: StreamConfigurationModel
    @State private var isKeyVisible = false
    @FocusState private var focusedField: Field?

    private enum Field { case ingestURL, streamKey }

    init(store: any StreamSettingsStoring) {
        _model = State(initialValue: StreamConfigurationModel(store: store))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(Strings.ingestPlaceholder, text: $model.ingestURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .ingestURL)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .streamKey }
                } header: {
                    Text(Strings.serverHeader)
                } footer: {
                    Text(Strings.serverFooter)
                }

                Section {
                    streamKeyField
                    Toggle(Strings.showStreamKey, isOn: $isKeyVisible)
                } header: {
                    Text(Strings.streamKeyHeader)
                } footer: {
                    Text(Strings.streamKeyFooter)
                }

                if let problem = model.problem {
                    Section {
                        problemRow(problem)
                    }
                }

                Section {
                    Button(Strings.saveAndContinue) {
                        focusedField = nil
                        model.saveAndContinue()
                    }
                    .disabled(!model.canContinue)
                }
            }
            .navigationTitle(Strings.navigationTitle)
            .onChange(of: model.ingestURL) { model.entryChanged() }
            .onChange(of: model.streamKey) { model.entryChanged() }
            .navigationDestination(item: $model.endpoint) { endpoint in
                StreamView(endpoint: endpoint)
            }
        }
    }

    @ViewBuilder
    private var streamKeyField: some View {
        if isKeyVisible {
            TextField(Strings.streamKeyPlaceholder, text: $model.streamKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .streamKey)
                .submitLabel(.done)
                .onSubmit(submitFromStreamKeyField)
        } else {
            SecureField(Strings.streamKeyPlaceholder, text: $model.streamKey)
                .textInputAutocapitalization(.never)
                // Not an account password: without this, iOS offers to save it to the user's
                // passwords, which is pointless since the app already keeps it in the keychain.
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .streamKey)
                .submitLabel(.done)
                .onSubmit(submitFromStreamKeyField)
        }
    }

    private func submitFromStreamKeyField() {
        guard model.canContinue else { return }
        focusedField = nil
        model.saveAndContinue()
    }

    private func problemRow(_ problem: StreamConfigurationModel.Problem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            if let suggestion = problem.suggestion {
                Text(suggestion)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    StreamConfigurationView(store: InMemoryStreamSettingsStore())
}
