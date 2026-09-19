import SwiftUI

/// Componenti condivisi che danno alle schermate custom dell'app (es.
/// `SourcesView`, `EPGManageView`, `SourceManagerView`) lo stesso aspetto
/// Liquid Glass: una `ScrollView` con sfondo sfumato, sezioni introdotte da
/// `GlassSectionHeader` e un'unica `GlassCard` per sezione che raccoglie le
/// sue righe (`GlassSettingsRow` / `GlassSourceRowLabel`) separate da
/// `GlassRowDivider`.
extension View {
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

/// Etichetta di sezione in maiuscolo, stessa tipografia usata da
/// `EPGManageView`/`SourceManagerView` per intestare i gruppi di card.
struct GlassSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
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
