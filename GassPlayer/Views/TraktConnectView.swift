import SwiftUI
import UIKit

/// Schermata "Trakt.tv": collega realmente l'account tramite il flusso
/// "device code" (`TraktAccountManager` + `TraktService`, già presenti nel
/// progetto ma mai esposti in una UI). Stile coerente con le altre
/// schermate custom Liquid Glass (`SourceManageView`, `EPGManageView`).
struct TraktConnectView: View {
    @ObservedObject private var account = TraktAccountManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if account.isConnected {
                        connectedCard
                    } else {
                        credentialsCard

                        if let deviceCode = account.deviceCode {
                            deviceCodeCard(deviceCode)
                        } else {
                            GlassPrimaryButton(
                                title: account.isConnecting ? "Avvio…" : "Connetti a Trakt.tv",
                                systemImage: "checkmark.seal"
                            ) {
                                account.startDeviceFlow()
                            }
                            .disabled(!account.hasCredentials || account.isConnecting)
                            .opacity(account.hasCredentials ? 1 : 0.5)
                        }
                    }

                    if let error = account.connectionError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    aboutCard
                }
                .padding(20)
            }
            .background(background)
            .navigationTitle("Trakt.tv")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .modifier(GlassCardBackground(cornerRadius: 18))
                    .accessibilityLabel("Indietro")
                }
            }
            .onDisappear {
                if account.deviceCode != nil {
                    account.cancelConnecting()
                }
            }
        }
    }

    // MARK: - Connesso

    private var connectedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connesso a Trakt.tv")
                            .font(.headline)
                        if let connectedAt = account.connectedAt {
                            Text("Dal \(connectedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }

                Text("La riproduzione di film e serie verrà segnalata a Trakt.tv per tenere traccia dei progressi.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    account.disconnect()
                } label: {
                    Label("Disconnetti", systemImage: "xmark.seal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Credenziali app Trakt

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldBlock(title: "Client ID") {
                TextField("Client ID dell'app Trakt.tv", text: $account.clientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .disabled(account.isConnecting)

            fieldBlock(title: "Client Secret") {
                SecureField("Client Secret dell'app Trakt.tv", text: $account.clientSecret)
            }
            .disabled(account.isConnecting)
        }
    }

    // MARK: - Codice dispositivo

    private func deviceCodeCard(_ code: TraktDeviceCode) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("In attesa di autorizzazione…")
                        .font(.subheadline.weight(.semibold))
                }

                Text("Apri il link qui sotto su qualsiasi dispositivo, accedi a Trakt.tv e inserisci questo codice:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(code.userCode)
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .tracking(2)

                    Spacer()

                    Button {
                        UIPasteboard.general.string = code.userCode
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copia codice")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let url = URL(string: "https://\(code.verificationUrl)") ?? URL(string: code.verificationUrl) {
                    Link(destination: url) {
                        Label(code.verificationUrl, systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                Button("Annulla") {
                    account.cancelConnecting()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Info

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Serve un'app Trakt.tv")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Registra un'app gratuita su trakt.tv/oauth/applications e incolla qui il Client ID e il Client Secret generati. Le credenziali restano solo su questo dispositivo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fieldBlock<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.10),
                Color(uiColor: .systemBackground),
                Color.purple.opacity(0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
