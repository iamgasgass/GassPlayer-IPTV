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
                        TextField("Host (es. http://server.dominio.com:8080)", text: $host)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        TextField("Username", text: $username)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                        SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                        Text("Formato host corretto: schema + dominio/IP + porta, senza percorsi finali. Esempio valido: http://miodominio.com:8080")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        TextField("URL playlist M3U/M3U8", text: $m3uURL)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

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
            let credentials = XtreamCredentials(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            let service = XtreamAPIService(credentials: credentials)
            do {
                _ = try await service.authenticate()
                onLogin(credentials)
            } catch let error as XtreamError {
                // Messaggio specifico per causa reale, non più un errore generico unico.
                errorMessage = error.errorDescription
            } catch {
                errorMessage = "Errore imprevisto: \(error.localizedDescription)"
            }
        } else {
            if let url = URL(string: m3uURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                onM3ULoaded(url)
            } else {
                errorMessage = "URL playlist non valido."
            }
        }
        isLoading = false
    }
}
