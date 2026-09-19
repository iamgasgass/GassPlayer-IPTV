import SwiftUI

/// Estensioni che portano l'estetica Liquid Glass di `GlassCard` /
/// `SourceManageView` dentro una `List` di sistema, per le schermate che —
/// come `SourcesView` — hanno bisogno delle funzioni native della lista
/// (`.searchable`, `.swipeActions`, `.onMove`, `EditButton`) ma devono
/// avere lo stesso identico linguaggio visivo delle schermate custom
/// dell'app (in particolare `HomeView`).
///
/// Costante unica di ritmo verticale: metà spazio sopra + metà sotto ogni
/// riga (card, header o footer) = questo valore raddoppiato è il distacco
/// visibile tra due elementi consecutivi qualsiasi della lista. Usata da
/// `glassListRow()`, `glassHeaderRow()` e `glassFooterRow()` così i tre
/// distacchi (card→card, header→card, card→footer) sono *matematicamente*
/// identici, non solo visivamente simili.
private let glassRowVerticalInset: CGFloat = 8

extension View {
    /// Sfondo "vetro" per una riga di `List`: stesso identico rendering di
    /// `GlassCardBackground` (usato da `GlassCard` in `HomeView`), non una
    /// sua imitazione.
    func glassListRow(cornerRadius: CGFloat = 16) -> some View {
        listRowInsets(
            EdgeInsets(
                top: glassRowVerticalInset,
                leading: 16,
                bottom: glassRowVerticalInset,
                trailing: 16
            )
        )
        .listRowSeparator(.hidden)
        .listRowBackground(GlassListRowBackground(cornerRadius: cornerRadius))
    }

    /// Riga "header" in stile Liquid Glass: stesso identico ritmo verticale
    /// (8pt sopra + 8pt sotto = 16pt) delle card prodotte da
    /// `.glassListRow()`, ma senza sfondo/vetro proprio — è solo
    /// un'etichetta di sezione, non una card.
    ///
    /// FIX MANIACALE — "le tab devono essere esattamente distanziate come
    /// tra 'Live TV' e 'Guarda tutte le liste insieme'": prima l'etichetta
    /// di sezione veniva passata al parametro `header:` di `Section`, che
    /// in una `List` riceve un padding verticale **proprio**, gestito dal
    /// sistema e indipendente dai `listRowInsets` delle righe. Il distacco
    /// header→prima card poteva quindi differire, anche di poco, dal
    /// distacco card→card. Rendendo l'etichetta una riga vera e propria con
    /// gli stessi identici insets delle card (e rimuovendo il parametro
    /// `header:` da `Section`), il distacco è ora lo stesso identico
    /// calcolo (8+8=16pt) in entrambi i casi: non più un'approssimazione.
    func glassHeaderRow() -> some View {
        listRowInsets(
            EdgeInsets(
                top: glassRowVerticalInset,
                leading: 16,
                bottom: glassRowVerticalInset,
                trailing: 16
            )
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Variante per i footer di sezione (note/avvertenze sotto l'ultima
    /// card): stesso principio di `glassHeaderRow()`, stesso ritmo
    /// verticale, per lo stesso motivo — coerenza totale del distacco in
    /// ogni punto della lista, non solo tra header e prima card.
    func glassFooterRow() -> some View {
        listRowInsets(
            EdgeInsets(
                top: glassRowVerticalInset,
                leading: 16,
                bottom: glassRowVerticalInset,
                trailing: 16
            )
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
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

    /// Da applicare alla `List` stessa (non alle righe): stile piatto senza
    /// il raggruppamento automatico di sistema, sfondo nativo nascosto,
    /// gradiente Liquid Glass e distacco tra sezioni uguale (16pt) al
    /// distacco tra le righe, per lo stesso motivo di `glassHeaderRow()`:
    /// un'unica costante di ritmo verticale per tutta la lista, così ogni
    /// "tab" flottante — che sia una card, un'etichetta o il passaggio da
    /// una sezione all'altra — è distanziata esattamente allo stesso modo.
    func glassListContainer() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .glassScreenBackground()
            .modifier(GlassListSectionSpacing())
    }
}

/// Applica `.listSectionSpacing(_:)` (disponibile da iOS 17) con lo stesso
/// valore (16pt = 2×`glassRowVerticalInset`) usato per il distacco tra le
/// righe, così il passaggio da una `Section` all'altra non introduce un
/// quarto valore di spaziatura diverso dai tre già unificati sopra.
private struct GlassListSectionSpacing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.listSectionSpacing(glassRowVerticalInset * 2)
        } else {
            content
        }
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
/// Va sempre usata insieme a `.glassHeaderRow()` (non più passata al
/// parametro `header:` di `Section`) per garantire il ritmo verticale
/// unificato descritto sopra.
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
