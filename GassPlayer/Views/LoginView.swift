import SwiftUI

struct LoginView: View {
    @State private var mode: SourceMode = .xtream
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var m3uURL = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    var onLogin: (XtreamCredentials) -> Void
    var onM3ULoaded: (URL) -> Void

    enum SourceMode: String, CaseIterable { case xtream = "Xtream Codes", m3u = "M3U / M3U8" }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, .indigo.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            GlassCard {
                VStack(spacing: 16) {
                    Text("Aggiungi la tua lista IPTV").font(.title2.bold())
                    Picker("Tipo sorgente", selection: $mode) {
                        ForEach(SourceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if mode == .xtream {
                        TextField("Host (es. http://server:port)", text: $host)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                        TextField("Username", text: $username)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                        SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                    } else {
                        TextField("URL playlist M3U/M3U8", text: $m3uURL)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }

                    if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }

                    GlassPrimaryButton(title: isLoading ? "Verifica in corso..." : "Accedi") {
                        Task { await submit() }
                    }
                    .disabled(isLoading || !isValid)
                }
                .padding()
            }
            .padding(.horizontal, 24)
        }
    }

    private var isValid: Bool {
        mode == .xtream ? (!host.isEmpty && !username.isEmpty && !password.isEmpty) : !m3uURL.isEmpty
    }

    private func submit() async {
        isLoading = true; errorMessage = nil
        if mode == .xtream {
            let credentials = XtreamCredentials(host: host, username: username, password: password)
            let service = XtreamAPIService(credentials: credentials)
            do { _ = try await service.authenticate(); onLogin(credentials) }
            catch { errorMessage = "Credenziali non valide o server non raggiungibile." }
        } else {
            if let url = URL(string: m3uURL) { onM3ULoaded(url) }
            else { errorMessage = "URL playlist non valido." }
        }
        isLoading = false
    }
}
