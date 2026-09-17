import SwiftUI

/// Estensioni che portano l'estetica Liquid Glass di `GlassCard` /
/// `SourceManageView` dentro una `List` di sistema, per le schermate che —
/// come `SourcesView` — hanno bisogno delle funzioni native della lista
/// (`.searchable`, `.swipeActions`, `.onMove`, `EditButton`) ma devono
/// avere lo stesso linguaggio visivo delle schermate custom dell'app.
extension View {
    /// Sfondo "vetro" per una riga di `List`: rettangolo arrotondato
    /// traslucido al posto dello sfondo di sistema, separatore nascosto
    /// (il distacco tra le righe è dato dal margine della card stessa).
    /// Da usare insieme a `.scrollContentBackground(.hidden)` sulla `List`
    /// e a `.glassScreenBackground()` per il gradiente sullo sfondo.
    func glassListRow() -> some View {
        listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thickMaterial)
            )
    }

    /// Sfondo di schermata coerente con `SourceManageView`, `EPGManageView`
    /// e `TraktConnectView`: stesso gradiente, per un aspetto Liquid Glass
    /// uniforme in tutta l'app.
    func glassScreenBackground() -> some View {
        background(
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
        )
    }
}

/// Cerchio icona colorato usato per identificare una sorgente per tipo,
/// stessa proporzione (44×44) e stessa palette di `SourceManagerView`.
struct GlassSourceIcon: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
    }
}

/// Contenuto di riga in stile Liquid Glass per un `NavigationLink`: icona in
/// cerchio colorato + titolo, senza il proprio `Button` (il tocco e la
/// chevron sono già forniti dal `NavigationLink` che lo ospita — usarci
/// dentro `GlassSettingsRow`, che è essa stessa un `Button`, creerebbe un
/// conflitto di gesture).
struct GlassSourceRowLabel: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            GlassSourceIcon(systemImage: icon, tint: tint, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 13)
    }
}

/// Colore identificativo per tipo di sorgente, condiviso da `SourcesView`
/// e `SourceManagerView` così la stessa sorgente ha sempre lo stesso colore
/// ovunque compaia nell'app.
extension MediaSourceType {
    var glassTint: Color {
        switch self {
        case .xtream: return .orange
        case .m3u8: return .blue
        case .plex: return .yellow
        case .jellyfin: return .purple
        case .emby: return .green
        }
    }
}
