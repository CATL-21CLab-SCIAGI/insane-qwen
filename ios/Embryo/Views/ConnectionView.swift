import SwiftUI

struct ConnectionView: View {
    @Environment(EmbryoStore.self) private var store
    @State private var endpoint = EmbryoStore.defaultEndpoint
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: store.connected ? "checkmark.shield.fill" : "network").foregroundStyle(store.connected ? EmbryoStyle.green : .secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.connection).font(.headline)
                            Text("Private Tailscale gateway").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.checking { ProgressView() }
                    }.padding(.vertical, 8)
                    if let error = store.connectionError { Text(error).font(.subheadline).foregroundStyle(.orange).textSelection(.enabled) }
                    if let count = store.sandboxCount, store.connected {
                        Text("\(count) of 4 sandbox slots in use at last check").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Endpoint", text: $endpoint, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.subheadline.monospaced()).accessibilityIdentifier("connection.endpoint")
                    Label("Your Tailscale identity connects automatically. No token needed.", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { await store.saveConnection(endpoint: endpoint) }
                    } label: { Text(store.checking ? "Checking…" : "Save & connect").fontWeight(.semibold) }
                        .disabled(store.checking || store.activeCount > 0 || store.isDemo).accessibilityIdentifier("connection.save")
                } header: { Text("Gateway") } footer: {
                    Text("Only dsw-evergreen.tail1c6dfa.ts.net is allowed. HTTP uses port 8090 inside the encrypted Tailscale network. HTTPS is available only after certificates are enabled on the server.")
                }
                Section("Before you connect") {
                    Label("Enable Tailscale on this iPhone and join the same tailnet as dsw-evergreen.", systemImage: "1.circle")
                    Label("Use your authorized Tailscale account; the gateway verifies your identity.", systemImage: "2.circle")
                    Label("Tap Save & connect to load available models and sandbox images.", systemImage: "3.circle")
                }.font(.subheadline)
                Section("During an experiment") {
                    Text("Keep Embryo open. Leaving the app closes active streams; the server stops after detecting the disconnect. Cleanup can be delayed while model generation or a tool command is in progress.")
                    Text("A dropped stream is never resumed or re-run automatically. Refresh History to recover the saved transcript, then choose Reuse task if needed.")
                }.font(.caption).foregroundStyle(.secondary)
                Section("Your research notebook") {
                    Text("No analytics or third-party SDKs. Transcripts and labels are saved locally with iOS file protection and excluded from backups. The gateway also stores server transcripts. Sharing JSON is always your choice.")
                    Text("Connection checks establish gateway reachability. The first experiment also tests the model and sandbox services.")
                }.font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("Connection")
                .onAppear { endpoint = store.endpoint }

        }
    }
}
