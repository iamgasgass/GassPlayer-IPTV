import SwiftUI

/// Estensioni che portano l'estetica Liquid Glass di `GlassCard` /
/// `SourceManageView` dentro una `List` di sistema, per le schermate che —
/// come `SourcesView` — hanno bisogno delle funzioni native della lista
/// (`.searchable`, `.swipeActions`, `.onMove`, `EditButton`) ma devono
/// avere lo stesso identico linguaggio visivo delle schermate custom
/// dell'app (in particolare `HomeView`).
extension View {
    /// Sfondo "vetro" per una riga di `List`: stesso identico rendering di
    /// `GlassCardBackground` (usato da `GlassCard` in `HomeView`), non una
    /// sua imitazione.
    ///
    /// FIX MANIACALE: la versione precedente applicava sempre e solo
    /// `.thickMaterial`, indipendentemente dalla versione di iOS. Questo
    /// è esattamente il motivo per cui le righe di `SourcesView` NON
    /// avevano lo stesso aspetto "Liquid Glass" di `HomeView`: su iOS 26+
    /// `HomeView` usa il vero `.glassEffect(.regular, in:)` (rifrangimento
    /// reale del vetro), mentre `SourcesView` restava con un materiale
    /// opaco statico che non reagisce mai come vetro. Ora entrambi i rami
    /// (`iOS 26+` / fallback) sono identici, carattere per carattere, a
    /// quelli di `GlassCardBackground`.
    func glassListRow(cornerRadius: CGFloat = 16) -> some View {
        listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(GlassListRowBackground(cornerRadius: cornerRadius))
    }

    /// Sfondo di schermata coerente con `SourceManageView`, `EPGManageView`,
    /// `TraktConnectView` **e** `HomeView`: stesso identico gradiente.
    ///
    /// FIX MANIACALE: le opacità erano 0.10/0.06, mentre `HomeView.background`
    /// usa 0.12/0.08. Una differenza minima ma percepibile che rendeva lo
    /// sfondo di `SourcesView` visibilmente "più spento" rispetto a Home.
    /// Ora i valori sono identici.
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

    /// Da applicare alla `List` stessa (non alle righe): stile piatto senza
    /// il raggruppamento automatico di sistema, sfondo nativo nascosto e
    /// gradiente Liquid Glass. Combinata con `.glassListRow()` su ogni riga,
    /// produce le card distanziate in modo uniforme richieste per
    /// `SourcesView`; usarla è ciò che rende `.glassListRow()` visibile
    /// come card separate invece che come un unico blocco per sezione.
    func glassListContainer() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .glassScreenBackground()
    }
}

/// Vista di sfondo per una riga di `List`, identica nel rendering a
/// `GlassCardBackground` (stesso `glassEffect`/fallback), estratta come
/// tipo a sé perché `.listRowBackground(_:)` richiede una `View` concreta
/// e non un `ViewModifier` applicato al contenuto della riga.
private struct GlassListRowBackground: View {
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
/// Necessaria perché `.listStyle(.plain)` (richiesto da `.glassListRow()`
/// per evitare che le righe di una sezione appaiano come un unico blocco,
/// vedi `glassListContainer()`) non applica da solo lo stile piccolo e
/// grigio delle intestazioni "insetGrouped".
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

// MARK: - Pillola flottante condivisa (floating tab)

/// Pillola "Liquid Glass" flottante da usare in `.principal` nella toolbar,
/// come selettore/menu a tendina. Estratta da `HomeView` (che la usava come
/// proprietà privata `homeMenuPillLabel`) e generalizzata così **qualunque**
/// schermata — `HomeView`, `SourcesView`, o altre in futuro — ottiene
/// esattamente lo stesso identico "floating tab" invocando lo stesso
/// identico codice, non una copia potenzialmente divergente.
///
/// Questo è il pezzo che risolve la richiesta "FLOATING TAB SEPARATE COME
/// IN HOMEVIEW": prima `SourcesView` aveva solo un'icona di ordinamento in
/// trailing, senza alcuna pillola flottante equivalente a quella di Home.
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
