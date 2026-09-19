import SwiftUI

/// Estensioni che portano l'estetica Liquid Glass di `GlassCard` dentro
/// contenitori sia `List` (per le schermate che ne hanno ancora bisogno)
/// sia `VStack`/`ScrollView` (come `SourcesView`, che non usa più `List`).
extension View {
    /// Sfondo "vetro" per una riga di `List`, stesso rendering di
    /// `GlassCardBackground`: `.glassEffect` reale su iOS 26+, fallback
    /// `.ultraThinMaterial` + bordo altrimenti.
    func glassListRow(cornerRadius: CGFloat = 16) -> some View {
        listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(GlassListRowBackground(cornerRadius: cornerRadius))
    }

    /// Da applicare alla `List` stessa (non alle righe): stile piatto senza
    /// il raggruppamento automatico di sistema, sfondo nativo nascosto e
    /// gradiente Liquid Glass.
    func glassListContainer() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .glassScreenBackground()
    }

    /// Equivalente di `glassListRow()` per contenuti **fuori** da `List`
    /// (`VStack`/`ScrollView`, come in `HomeView` e — dopo la rimozione del
    /// contenitore `List` — in `SourcesView`). Applica lo stesso identico
    /// sfondo vetro come `.background(_:)` invece che come
    /// `.listRowBackground(_:)`, con lo stesso padding orizzontale/verticale
    /// che prima veniva dato dagli inset di riga.
    func glassTab(cornerRadius: CGFloat = 16) -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(GlassListRowBackground(cornerRadius: cornerRadius))
    }

    /// Sfondo di schermata coerente con `SourceManageView`, `EPGManageView`,
    /// `TraktConnectView` e `HomeView`: stesso identico gradiente.
    func glassScreenBackground() -> some View {
        background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.12),
                    Color(uiColor: .systemBackground),
                    Color.purple.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }
}

/// Vista di sfondo Liquid Glass condivisa da `.glassListRow()` (dentro
/// `List`) e `.glassTab()` (fuori da `List`), così il rendering è
/// letteralmente lo stesso codice nei due contesti.
struct GlassListRowBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular,
                    in: .rect(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                }
        }
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
/// chevron sono già forniti dal `NavigationLink` che lo ospita).
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

            Spacer()
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

// MARK: - Pillola flottante condivisa (floating tab)

/// Pillola "Liquid Glass" flottante da usare in `.principal` nella toolbar,
/// come selettore/menu a tendina. Condivisa carattere per carattere da
/// `HomeView` e `SourcesView`.
struct GlassMenuPillLabel: View {
    let systemImage: String
    let title: String
    var tint: Color = .accentColor
    var minWidth: CGFloat = 142
    var maxWidth: CGFloat = 260

    var body: some View {
        let pill = HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)

            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 17)
        .frame(minWidth: minWidth, maxWidth: maxWidth, minHeight: 44)
        .contentShape(Capsule())

        return Group {
            if #available(iOS 26.0, *) {
                pill.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                pill
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                    }
            }
        }
    }
}
