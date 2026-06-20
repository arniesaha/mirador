import SwiftUI

struct ContentView: View {
    @AppStorage("mirador.host") private var host = "192.168.1.149"
    @AppStorage("mirador.port") private var port = "8787"
    @AppStorage("mirador.token") private var token = ""
    @State private var session: RemoteSession?

    var body: some View {
        Group {
            if let session {
                RemoteScreenView(session: session) {
                    session.stop()
                    self.session = nil
                }
            } else {
                connectForm
            }
        }
        .onAppear(perform: maybeAutoConnect)
    }

    /// Auto-connect when launched with MIRADOR_AUTOCONNECT in the environment (used for
    /// automated/simulator runs and as a deep-link/automation hook). Falls back to stored fields.
    private func maybeAutoConnect() {
        let env = ProcessInfo.processInfo.environment
        guard session == nil, env["MIRADOR_AUTOCONNECT"] != nil else { return }
        let config = ServerConfig(
            host: env["MIRADOR_HOST"] ?? host,
            port: env["MIRADOR_PORT"] ?? port,
            token: env["MIRADOR_TOKEN"] ?? token
        )
        session = RemoteSession(config: config)
    }

    private var connectForm: some View {
        NavigationStack {
            Form {
                Section("Mac host") {
                    TextField("Host or IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    SecureField("Token", text: $token)
                }
                Section {
                    Button {
                        let config = ServerConfig(host: host.trimmingCharacters(in: .whitespaces),
                                                  port: port.trimmingCharacters(in: .whitespaces),
                                                  token: token.trimmingCharacters(in: .whitespaces))
                        session = RemoteSession(config: config)
                    } label: {
                        Label("Connect", systemImage: "play.display")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(host.isEmpty || port.isEmpty)
                }
            }
            .navigationTitle("Mirador")
        }
    }
}
