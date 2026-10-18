import SwiftUI

// MARK: - Rail "Categorie TV"

/// "Categorie TV" (menu "…" → "UI Gruppi", come nel progetto Android): i
/// gruppi della playlist, che prima erano la sezione "Categorie" di
/// "Modifica", diventano un rail verticale a sinistra dei contenuti. Il rail
/// usa righe con icona, nome e conteggio dei contenuti, come la rail Android;
/// la selezione riprende la pillola Liquid Glass interattiva della barra
/// inferiore di File: unica, neutra e animata tra le voci, senza tinta accent.
/// Il pannello mantiene il layout verticale necessario alla rail. In cima,
/// come su Android, "Preferiti" e
/// "Tutti", poi "Senza categoria" se serve e i gruppi nell'ordine della
/// playlist.
struct CategoryRailItem: Identifiable, Hashable {
    let id: String
    let name: String
    /// Stessa semantica delle icone della rail Android: preferiti, tutti e gruppi.
    let icon: String
    /// Contenuti effettivi della playlist appartenenti a questa voce.
    let count: Int
}

/// Chiavi riservate delle voci fisse del rail (non collidono con i
/// `category_id` Xtream, che sono numerici o stringhe del provider).
enum CategoryRailKey {
    static let favorites = "__gassplayer_rail_favorites__"
    static let all = "__gassplayer_rail_all__"
    static let uncategorized = "__gassplayer_rail_uncategorized__"

    /// Voci fisse in cima al rail ("Preferiti", "Tutti"), separate dai
    /// gruppi da un filo.
    static func isPinned(_ id: String) -> Bool {
        id == favorites || id == all
    }
}

/// Misure di contenuto della rail; la selezione usa la pillola Capsule della
/// barra inferiore di File, indipendentemente dall'altezza della riga.
struct CategoryRailMetrics: Equatable {
    var rowHeight: CGFloat
    var horizontalPadding: CGFloat
    var fontSize: CGFloat
    var spacing: CGFloat

    /// `TvCategoryRail` (Live TV / VOD / Serie TV / Guida).
    static let rail = CategoryRailMetrics(
        rowHeight: 48,
        horizontalPadding: 11,
        fontSize: 14,
        spacing: 5
    )

    /// Colonna "GRUPPI" del rail nel player (`PlayerLiveCategoryRail`).
    static func playerGroups(compact: Bool) -> CategoryRailMetrics {
        CategoryRailMetrics(
            rowHeight: compact ? 40 : 44,
            horizontalPadding: 8,
            fontSize: compact ? 10 : 12,
            spacing: 4
        )
    }
}

/// Riga del rail nello stile della barra inferiore di File: le voci inattive
/// non hanno una pillola propria; l'unica lente Liquid Glass è condivisa e
/// migra alla voce selezionata usando l'identità nativa degli effetti glass.
struct CategoryRailTile: View, Equatable {
    let name: String
    let icon: String
    let count: Int
    let isSelected: Bool
    let metrics: CategoryRailMetrics
    let selectionNamespace: Namespace.ID
    /// Vetro leggero per rail sovrapposti al player.
    var isTransparent = false
    let action: () -> Void

    static func == (lhs: CategoryRailTile, rhs: CategoryRailTile) -> Bool {
        lhs.name == rhs.name && lhs.icon == rhs.icon && lhs.count == rhs.count
            && lhs.isSelected == rhs.isSelected && lhs.metrics == rhs.metrics
            && lhs.isTransparent == rhs.isTransparent
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                action()
            }
        } label: {
            ZStack {
                if isSelected {
                    Capsule()
                        .fill(.clear)
                        .modifier(CategoryRailSelectionLens(
                            selectionNamespace: selectionNamespace,
                            isTransparent: isTransparent
                        ))
                        .zIndex(1)
                }

                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.70))
                        .frame(width: 18)
                        .accessibilityHidden(true)

                    Text(name)
                        .font(.system(size: metrics.fontSize, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .frame(maxWidth: .infinity, minHeight: metrics.rowHeight, maxHeight: metrics.rowHeight, alignment: .leading)
                .zIndex(2)
            }
            .frame(maxWidth: .infinity, minHeight: metrics.rowHeight, maxHeight: metrics.rowHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(count) contenuti")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CategoryRail: View {
    let items: [CategoryRailItem]
    let selectedID: String
    @Namespace private var selectionNamespace
    var width: CGFloat = 236
    /// Intestazione "Categorie TV" (stessa tipografia dell'intestazione
    /// "Categorie" della vecchia sezione). `false` nel player, dove sopra la
    /// colonna c'è l'etichetta "GRUPPI".
    var showsHeader = true
    /// Pannello Liquid Glass dietro al rail (stesso vetro delle tessere).
    /// `false` solo nel player, dove il rail sta nel pannello del player.
    var showsPanel = true
    var metrics: CategoryRailMetrics = .rail
    /// Tessere in vetro trasparente (rail del player).
    var isTransparent = false
    let onSelect: (String) -> Void

    var body: some View {
        let rail = VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                Text("Categorie TV")
                    .font(.system(size: 18.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }

            list
        }

        if showsPanel {
            rail
                .padding(10)
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .top)
                .modifier(CategoryRailPanel(cornerRadius: 22))
        } else {
            rail
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // iOS 26 usa il contenitore nativo per far migrare la stessa
                // superficie Liquid Glass fra le righe, come nella barra tab
                // di File. Sui sistemi precedenti resta attivo il fallback.
                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: max(metrics.rowHeight + metrics.spacing, 56)) {
                        railRows
                    }
                    .padding(.vertical, 2)
                } else {
                    railRows
                        .padding(.vertical, 2)
                }
            }
            // Il gruppo selezionato è sempre visibile all'apertura e dopo
            // ogni cambio (anche se scelto altrove, es. dal player).
            .onAppear {
                proxy.scrollTo(selectedID, anchor: .center)
            }
            .onChange(of: selectedID) { _, newID in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var railRows: some View {
        LazyVStack(spacing: metrics.spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                // Filo fra le voci fisse ("Preferiti", "Tutti") e i gruppi.
                if index > 0,
                   !CategoryRailKey.isPinned(item.id),
                   CategoryRailKey.isPinned(items[index - 1].id) {
                    Divider()
                        .overlay(Color.white.opacity(0.14))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 7)
                }

                CategoryRailTile(
                    name: item.name,
                    icon: item.icon,
                    count: item.count,
                    isSelected: item.id == selectedID,
                    metrics: metrics,
                    selectionNamespace: selectionNamespace,
                    isTransparent: isTransparent
                ) {
                    onSelect(item.id)
                }
                .equatable()
                .id(item.id)
            }
        }
    }
}

/// Lente singola della rail: usa lo stesso materiale Liquid Glass interattivo
/// della tab bar di sistema. `glassEffectID` è l'identità condivisa che consente
/// a iOS 26 di trasformare/spostare la lente fra due voci, invece di ridisegnare
/// capsule indipendenti per ogni riga.
private struct CategoryRailSelectionLens: ViewModifier {
    let selectionNamespace: Namespace.ID
    var isTransparent = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    isTransparent ? .clear.interactive() : .regular.interactive(),
                    in: Capsule()
                )
                .glassEffectID("category-rail-active-tab", in: selectionNamespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(isTransparent ? 0.24 : 0.18), lineWidth: 0.6)
                }
                .matchedGeometryEffect(
                    id: "category-rail-active-tab",
                    in: selectionNamespace,
                    isSource: true
                )
        }
    }
}

/// Pannello dietro il rail (raggio 22; 25 nel player): STESSO vetro Liquid
/// Glass trasparente delle tessere "Categorie" (`CategoryGlassTile` non
/// selezionata), sia su iOS 26+ sia nel fallback.
struct CategoryRailPanel: ViewModifier {
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content.modifier(CategoryGlassTile(isSelected: false, cornerRadius: cornerRadius))
    }
}

// MARK: - Rail "Categorie TV" nel player (Live TV)

/// Dati con cui il player mostra il rail dei gruppi e dei canali live, come
/// il rail del player Android: gruppi a sinistra, canali del gruppo a
/// destra; la scelta di un canale cambia la riproduzione senza chiudere il
/// player né il rail.
struct PlayerChannelBrowser {
    let groups: [CategoryRailItem]
    /// Gruppo aperto all'apertura del rail: quello del canale in onda.
    let initialGroupID: String
    let currentChannelID: Int
    let imageBaseHost: String
    let channels: (String) -> [XtreamStream]
    let isFavorite: (XtreamStream) -> Bool
    let select: (XtreamStream) -> Void
}

/// Misure di `PlayerLiveCategoryRail` (Android): pannello 96% della
/// larghezza su telefono / 72% (max 760) su schermi larghi, alto 94%;
/// gruppi 126/224 pt; righe gruppo 40/44, righe canale 48/54, logo 28/38.
struct PlayerChannelRail: View {
    let browser: PlayerChannelBrowser
    /// Programma in onda del canale corrente, mostrato sotto il titolo e
    /// nella fascia "IN ONDA" in fondo.
    let programTitle: String?
    let onClose: () -> Void

    @State private var groupID: String
    @State private var channels: [XtreamStream] = []
    /// Incrementato ad ogni nuovo elenco canali: fa scorrere al canale in onda
    /// senza confrontare elenchi di migliaia di elementi ad ogni ridisegno.
    @State private var channelsRevision = 0

    private static let accentLight = Color(red: 0xBB / 255, green: 0xD0 / 255, blue: 0xFF / 255)
    private static let playingBorder = Color(red: 0x8C / 255, green: 0xB7 / 255, blue: 0xFF / 255)
    private static let favoriteStar = Color(red: 0xFF / 255, green: 0xD1 / 255, blue: 0x66 / 255)

    init(browser: PlayerChannelBrowser, programTitle: String?, onClose: @escaping () -> Void) {
        self.browser = browser
        self.programTitle = programTitle
        self.onClose = onClose
        _groupID = State(initialValue: browser.initialGroupID)
    }

    private var currentProgramTitle: String? {
        guard let programTitle, !programTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return programTitle
    }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 700
            let panelWidth = compact ? geo.size.width * 0.96 : min(geo.size.width * 0.72, 760)
            let groupWidth: CGFloat = compact ? 126 : 224

            ZStack(alignment: .leading) {
                // Velo leggero: il video resta visibile attraverso il vetro.
                // Un tocco fuori dal pannello chiude il rail.
                Color.black.opacity(compact ? 0.30 : 0.12)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }

                VStack(alignment: .leading, spacing: 0) {
                    header

                    Divider()
                        .overlay(Color.white.opacity(0.13))
                        .padding(.vertical, 5)

                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("GRUPPI")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.primary.opacity(0.55))
                                .padding(.leading, 7)
                                .padding(.bottom, 5)

                            CategoryRail(
                                items: browser.groups,
                                selectedID: groupID,
                                width: groupWidth,
                                showsHeader: false,
                                showsPanel: false,
                                metrics: .playerGroups(compact: compact)
                            ) { id in
                                groupID = id
                            }
                        }
                        .frame(width: groupWidth)

                        Divider().overlay(Color.white.opacity(0.12))

                        channelColumn(compact: compact)
                    }
                    .frame(maxHeight: .infinity)

                    if let currentProgramTitle {
                        Divider()
                            .overlay(Color.white.opacity(0.13))
                            .padding(.vertical, 6)

                        Text("IN ONDA")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Self.accentLight)

                        Text(currentProgramTitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(0.86))
                            .lineLimit(1)
                    }
                }
                .padding(compact ? 8 : 12)
                .frame(width: panelWidth, height: geo.size.height * 0.94, alignment: .top)
                // Stessa UI Liquid Glass trasparente del rail "Categorie TV":
                // il video resta visibile attraverso il pannello.
                .modifier(CategoryRailPanel(cornerRadius: 25))
                .padding(.leading, compact ? 6 : 22)
                .padding(.vertical, 12)
            }
        }
        .onAppear { loadChannels(groupID) }
        .onChange(of: groupID) { _, newID in loadChannels(newID) }
    }

    private func loadChannels(_ id: String) {
        channels = browser.channels(id)
        channelsRevision += 1
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "tv")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Self.accentLight)
                .frame(width: 23, height: 23)

            VStack(alignment: .leading, spacing: 0) {
                Text("Categorie TV")
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                Text(currentProgramTitle ?? "Gruppi e canali")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GlassIconButton(systemImage: "xmark", size: 38, accessibilityLabel: "Chiudi categorie") {
                onClose()
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
    }

    private func channelColumn(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CANALI")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.55))
                Spacer(minLength: 0)
                Text("\(channels.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.48))
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

            if channels.isEmpty {
                Text("Nessun canale nel gruppo")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                channelList(compact: compact)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func channelList(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 5) {
                    ForEach(Array(channels.enumerated()), id: \.element.streamId) { index, channel in
                        channelRow(channel, number: index + 1, compact: compact)
                            .id(channel.streamId)
                    }
                }
            }
            // All'apertura e ad ogni cambio gruppo: il canale in onda, se
            // presente nel gruppo, è subito visibile.
            .onAppear { scrollToPlaying(proxy, animated: false) }
            .onChange(of: channelsRevision) { _, _ in scrollToPlaying(proxy, animated: false) }
            .onChange(of: browser.currentChannelID) { _, _ in scrollToPlaying(proxy, animated: true) }
        }
    }

    private func scrollToPlaying(_ proxy: ScrollViewProxy, animated: Bool) {
        let target = browser.currentChannelID
        guard channels.contains(where: { $0.streamId == target }) else { return }
        // Dopo il layout del nuovo elenco.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
            } else {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    private func channelRow(_ channel: XtreamStream, number: Int, compact: Bool) -> some View {
        let isPlaying = channel.streamId == browser.currentChannelID
        let logoSize: CGFloat = compact ? 28 : 38

        return Button {
            browser.select(channel)
        } label: {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.50))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 22)

                if let icon = channel.streamIcon, !icon.isEmpty {
                    CachedPosterImage(
                        urlString: icon,
                        baseHost: browser.imageBaseHost,
                        width: logoSize,
                        height: logoSize,
                        cornerRadius: 0,
                        placeholderSymbol: "tv"
                    )
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .frame(width: 22, height: 22)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(channel.name)
                        .font(.system(size: compact ? 11 : 13, weight: isPlaying ? .semibold : .medium))
                        .foregroundStyle(Color.primary.opacity(isPlaying ? 1 : 0.86))
                        .lineLimit(1)
                    if isPlaying {
                        Text("IN RIPRODUZIONE")
                            .font(.system(size: 8))
                            .foregroundStyle(Self.accentLight)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if browser.isFavorite(channel) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Self.favoriteStar)
                        .frame(width: 13, height: 13)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: compact ? 48 : 54, maxHeight: compact ? 48 : 54, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        // Stesso vetro delle tessere Categorie: tinta d'accento sul canale in onda.
        .modifier(CategoryGlassTile(isSelected: isPlaying, cornerRadius: 13))
        .accessibilityLabel(channel.name)
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
    }
}
