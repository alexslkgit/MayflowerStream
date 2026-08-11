import SwiftUI

/// Screen 1 — Stream Configuration.
///
/// Nothing here touches the camera, the microphone or the network. The screen exists only to
/// collect and persist a destination; capture starts on screen 2, and only when the user asks for
/// it.
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
                    TextField("rtmp://…", text: $model.ingestURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .ingestURL)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .streamKey }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Twitch lists its ingest servers at ingest.twitch.tv. The one filled in is the closest European server.")
                }

                Section {
                    streamKeyField
                    Toggle("Show stream key", isOn: $isKeyVisible)
                } header: {
                    Text("Stream key")
                } footer: {
                    Text("On Twitch: Creator Dashboard → Settings → Stream. The key is stored in this device's keychain, not in plain text.")
                }

                if let problem = model.problem {
                    Section {
                        problemRow(problem)
                    }
                }

                Section {
                    Button("Save and continue") {
                        focusedField = nil
                        model.saveAndContinue()
                    }
                    .disabled(!model.canContinue)
                }
            }
            .navigationTitle("Stream setup")
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
            TextField("live_…", text: $model.streamKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .streamKey)
        } else {
            SecureField("live_…", text: $model.streamKey)
                .textInputAutocapitalization(.never)
                // A stream key is not an account password. Without this, iOS offers to save it to
                // the user's passwords the moment the screen is left, which is both confusing and
                // pointless — the app already keeps it in the keychain itself.
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .streamKey)
        }
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
