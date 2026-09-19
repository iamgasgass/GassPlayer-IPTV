import SwiftUI

/// Estensioni che portano l'estetica Liquid Glass di `GlassCard` dentro
/// layout custom (`ScrollView` + `VStack`, come `HomeView`) e — per le
/// schermate che avessero ancora bisogno di una `List` di sistema — dentro
/// una `List`. `SourcesView` non usa più la parte "List" da quando è stata
/// convertita a `ScrollView`, ma questi helper restano qui per eventuali
/// altre schermate dell'app che si affidano ancora a una `List` nativa.
extension View {
    /// Sfondo "vetro" per una riga di `List`: stesso identico rendering di
    /// `GlassCardBackground` (usato da `GlassCard`), non una sua imitazione.
    func glassListRow(cornerRadius: CGFloat = 16) -> some View {
        listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(GlassListRowBackground(cornerRadius: cornerRadius))
    }

    /// Sfondo di schermata coerente con `SourceManageView`, `EPGManageView`,
    /// `TraktConnectView` **e** `HomeView`: stesso identico gradiente.
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

    /// Da applicare a una `List` (non più usata da `SourcesView`, mantenuta
    /// per compatibilità con altre schermate che si affidano ancora a una
    /// `List` nativa con lo stesso linguaggio visivo).
    func glassListContainer() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .glassScreenBackground()
    }

    /// Sfondo "vetro" per una riga **fuori da una `List`** (dentro un
    /// `VStack`/`ScrollView`, come in `HomeView` e nella nuova
    /// `SourcesView`): stesso identico `GlassCardBackground` di `GlassCard`,
    /// applicato direttamente al contenuto della riga invece che passato a
    /// `.listRowBackground`. È l'equivalente "senza List" di
    /// `.glassListRow()`.
    func glassRow(cornerRadius: CGFloat = 16) -> some View {
        padding(.horizontal, 14)
            .modifier(GlassCardBackground(cornerRadius: cornerRadius))
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
struct GlassSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - Blocco di sezione senza List (fix spaziatura header→tab)

/// Blocco "sezione" per layout `ScrollView`/`VStack` (non `List`): titolo +
/// contenuto, con una distanza header→primo elemento **fissa e identica in
/// tutta l'app**.
///
/// FIX MANIACALE — spaziatura header→tab incoerente: prima `SourcesView`
/// usava una `List` di sistema con `Section`. UIKit calcola la distanza tra
/// l'header di una sezione e la sua prima riga in modo automatico e NON
/// costante: dipende da footer presenti/assenti, da header con più
/// sottoview (es. `HStack { GlassSectionHeader; Spacer(); Text(count) }`),
/// dal numero di righe. Il risultato percepito era che la sezione "Live
/// TV" → "Guarda tutte le liste insieme" (una sola riga, header semplice)
/// aveva una distanza diversa dalle altre sezioni con header composti o
/// più righe.
///
/// Rimuovendo la `List` e introducendo questo blocco, la distanza
/// header→primo elemento è la stessa identica costante (`headerSpacing`)
/// per **ogni** sezione, senza eccezioni: non c'è più alcun calcolo
/// automatico di sistema che possa farla divergere.
///
/// Il valore di `headerSpacing` (8pt) è scelto per non alterare la
/// distanza percepita: era esattamente il valore di `top` in
/// `EdgeInsets(top: 8, ...)` che `.glassListRow()` applicava come inset
/// superiore della prima riga — cioè lo stesso spazio che la sezione "Live
/// TV" mostrava già prima di questa modifica. Non è quindi un aumento di
/// spaziatura, ma la stessa distanza resa costante ovunque.
struct GlassSectionBlock<Content: View>: View {
    static let headerSpacing: CGFloat = 8

    let title: String
    var trailingText: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Self.headerSpacing) {
            HStack {
                GlassSectionHeader(title: title)

                if let trailingText {
                    Spacer()
                    Text(trailingText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                content
            }

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
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
/// come selettore/menu a tendina. Condivisa da `HomeView` e `SourcesView`:
/// un'unica fonte di verità per il "floating tab" Liquid Glass di tutta
/// l'app.
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
