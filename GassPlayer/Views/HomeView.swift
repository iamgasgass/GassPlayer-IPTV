import SwiftUI

/// Le viste selezionabili dal menu a tendina "Home": la panoramica normale
/// oppure i preferiti di una delle tre librerie, filtrati dal menu stesso.
enum HomeMenuSelection: Hashable, CaseIterable {
    case overview
    case favoritesLive
    case favoritesVOD
    case favoritesSeries

    var title: String {
        switch self {
        case .overview: return "Home"
        case .favoritesLive: return "Preferiti Live TV"
        case .favoritesVOD: return "Preferiti VOD"
        case .favoritesSeries: return "Preferiti Serie TV"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "house.fill"
        case .favoritesLive: return "tv.fill"
        case .favoritesVOD: return "film.fill"
        case .favoritesSeries: return "rectangle.stack.fill"
        }
    }

    var tint: Color {
        switch self {
        case .overview: return .accentColor
        case .favoritesLive: return .red
        case .favoritesVOD: return .purple
        case .favoritesSeries: return .blue
        }
    }

    /// Il valore di `FavoriteItem.kind` corrispondente (uguale a
    /// `XtreamStreamKind.rawValue`), `nil` per la panoramica.
    var favoriteKind: String? {
        switch self {
        case .overview: return nil
        case .favoritesLive: return XtreamStreamKind.live.rawValue
        case .favoritesVOD: return XtreamStreamKind.movie.rawValue
        case .favoritesSeries: return XtreamStreamKind.series.rawValue
        }
    }
}

struct HomeView: View {
    @Binding var selectedTab: MainTab
    let hasActiveSource: Bool

    @EnvironmentObject private var overlayState: NavigationOverlayState
    @EnvironmentObject private var sourceManager: SourceManager
    @EnvironmentObject private var contentManagement: ContentManagementService
    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore
    @EnvironmentObject private var m3uStore: M3UPlaylistStore
    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore

    @ObservedObject private var epgManager = EPGManager.shared

    @State private var homeMenuSelection: HomeMenuSelection = .overview
    @State private var showGuidaTV = false
    @State private var showGuidaTVUnavailableAlert = false
    @State private var showManageActiveSource = false

    /// Ordine/visibilità delle sezioni personalizzabili (foglio "Personalizza"):
    /// la Home osserva lo store, quindi ogni modifica si vede all'istante.
    @StateObject private var homeLayout = HomeLayoutStore()
    @State private var showCustomize = false
    @State private var homeLiveTarget: XtreamStream?
    @State private var homeMovieTarget: XtreamStream?
    @State private var homeSeriesTarget: XtreamSeriesItem?
    @State private var showTrendingUnavailable = false

    var body: some View {
        NavigationStack {
            Group {
                if homeMenuSelection == .overview {
                    overviewScroll
                } else {
                    favoritesScroll(kind: homeMenuSelection.favoriteKind ?? "")
                }
            }
            .background(background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbarContent
            }
            .fullScreenCover(isPresented: $showGuidaTV) {
                if let credentials = sourceManager.activeSource?.xtreamCredentials {
                    EPGGridView(credentials: credentials, kind: .live)
                        .environmentObject(xtreamCatalog)
                } else {
                    ContentUnavailableView(
                        "Guida TV non disponibile",
                        systemImage: "tv.slash",
                        description: Text("Attiva una sorgente Xtream per consultare la guida programmi.")
                    )
                }
            }
            .alert(
                "Guida TV non disponibile",
                isPresented: $showGuidaTVUnavailableAlert
            ) {
                Button("Vai alle sorgenti") { overlayState.showSettings = true }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("La guida programmi richiede una sorgente Xtream attiva. Aggiungine una dalle Impostazioni.")
            }
            .sheet(isPresented: $showCustomize) {
                HomeCustomizeSheet(layout: homeLayout)
            }
            .fullScreenCover(item: $homeLiveTarget) { stream in
                if let credentials = sourceManager.activeSource?.xtreamCredentials,
                   let url = XtreamAPIService(credentials: credentials).streamURL(for: stream, kind: .live) {
                    AdaptivePlayerView(url: url, title: stream.name)
                        .task {
                            recentlyWatched.record(
                                id: credentials.favoriteID(kind: .live, streamId: stream.streamId),
                                title: stream.name,
                                kind: XtreamStreamKind.live.rawValue,
                                streamURL: url
                            )
                        }
                } else {
                    ContentUnavailableView(
                        "URL dello stream non valido",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            .fullScreenCover(item: $homeMovieTarget) { stream in
                if let credentials = sourceManager.activeSource?.xtreamCredentials {
                    MovieDetailView(credentials: credentials, stream: stream)
                }
            }
            .fullScreenCover(item: $homeSeriesTarget) { series in
                if let credentials = sourceManager.activeSource?.xtreamCredentials {
                    SeriesEpisodesView(
                        credentials: credentials,
                        seriesId: series.seriesId,
                        seriesName: series.name,
                        fallbackCoverURLString: series.cover
                    )
                }
            }
            .alert("Non disponibile nella tua playlist", isPresented: $showTrendingUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Questo titolo di tendenza non è presente nella sorgente attiva.")
            }
            .sheet(isPresented: $showManageActiveSource) {
                if let activeSource = sourceManager.activeSource {
                    SourceManageView(source: activeSource)
                        .environmentObject(sourceManager)
                        .environmentObject(contentManagement)
                        .environmentObject(xtreamCatalog)
                        .environmentObject(m3uStore)
                }
            }
        }
    }

    // MARK: - Overview

    private var overviewScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // TUTTI i blocchi della Home, nell'ordine scelto da
                // "Personalizza" (foglio "Sezioni home").
                ForEach(homeLayout.order) { section in
                    sectionView(section)
                }

                // In fondo, come nel riferimento: apre "Sezioni home".
                HomePersonalizeButton {
                    showCustomize = true
                }
            }
            .animation(.snappy(duration: 0.25), value: homeLayout.order)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        // FIX: "Continua a guardare" compariva in Home solo dopo il
        // riavvio. La scheda Home vive in un `TabView` e, mentre è in
        // secondo piano, non è garantito che ridisegni la propria
        // gerarchia quando un contenuto viene registrato altrove (VOD,
        // Serie TV): ogni volta che la scheda torna visibile si rilegge
        // l'elenco e si forza l'aggiornamento.
        .onAppear {
            recentlyWatched.refresh()
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .home {
                recentlyWatched.refresh()
            }
        }
    }

    // MARK: - Sezioni personalizzabili

    @ViewBuilder
    private func sectionView(_ section: HomeSectionID) -> some View {
        switch section {
        case .heading:
            heading

        case .sourceCard:
            if hasActiveSource {
                connectedSourceCard
            } else {
                emptySourceCard
            }

        case .liveTV:
            libraryDestination(
                title: "Live TV",
                subtitle: hasActiveSource
                    ? "Canali in diretta dalla sorgente attiva"
                    : "I canali appariranno qui",
                systemImage: "tv.fill",
                tint: .red,
                destination: .liveTV
            )

        case .onDemand:
            onDemandSection

        case .sources:
            sourceSummary

        case .continueWatching:
            if recentlyWatched.items.contains(where: { homeLayout.continueKind == nil || $0.kind == homeLayout.continueKind }) {
                // Stessa sezione usata in VOD e Serie TV (qui tutti i tipi
                // o il tipo scelto dalle opzioni). Il contenitore ha 20 pt
                // di padding laterale: il padding negativo fa partire
                // header e card a filo schermo con il margine di 16 pt.
                ContinueWatchingSection(kindFilter: homeLayout.continueKind, horizontalInset: 16)
                    .padding(.horizontal, -20)
            }

        case .guidaTV:
            guidaTVDestination

        case .favoriteChannels:
            favoritesRail(section, kind: .live)

        case .favoriteSeries:
            favoritesRail(section, kind: .series)

        case .favoriteMovies:
            favoritesRail(section, kind: .movie)

        case .trendingSeries:
            HomeTrendingRail(title: section.title, isSeries: true, horizontalInset: 16) { item in
                openTrending(item)
            }
            .padding(.horizontal, -20)

        case .trendingMovies:
            HomeTrendingRail(title: section.title, isSeries: false, horizontalInset: 16) { item in
                openTrending(item)
            }
            .padding(.horizontal, -20)
        }
    }

    @ViewBuilder
    private func favoritesRail(_ section: HomeSectionID, kind: XtreamStreamKind) -> some View {
        if let credentials = sourceManager.activeSource?.xtreamCredentials {
            HomeFavoritesRail(
                title: section.title,
                kind: kind,
                horizontalInset: 16,
                credentials: credentials,
                onSelectLive: { homeLiveTarget = $0 },
                onSelectMovie: { homeMovieTarget = $0 },
                onSelectSeries: { homeSeriesTarget = $0 }
            )
            .padding(.horizontal, -20)
        }
    }

    /// Apre il contenuto equivalente nella sorgente attiva; se la sorgente
    /// non lo ha lo dice invece di non fare nulla.
    private func openTrending(_ item: TMDBTrendingItem) {
        guard sourceManager.activeSource?.xtreamCredentials != nil else {
            showTrendingUnavailable = true
            return
        }

        if item.isSeries {
            if let match = HomeTrendingMatcher.series(for: item, in: xtreamCatalog.seriesItems) {
                homeSeriesTarget = match
                return
            }
        } else if let match = HomeTrendingMatcher.movie(for: item, in: xtreamCatalog.vodStreams) {
            homeMovieTarget = match
            return
        }

        showTrendingUnavailable = true
    }

    // MARK: - Preferiti (menu "Home" a tendina)

    private func favoritesScroll(kind: String) -> some View {
        let items = contentManagement.favorites
            .filter { $0.kind == kind }
            .sorted { $0.addedAt > $1.addedAt }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(homeMenuSelection.title)
                        .font(.title2.bold())
                    Text(
                        items.isEmpty
                            ? "Non hai ancora aggiunto preferiti in questa sezione."
                            : "\(items.count) element\(items.count == 1 ? "o" : "i") salvat\(items.count == 1 ? "o" : "i")."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if items.isEmpty {
                    emptyFavoritesCard
                } else {
                    ForEach(items) { item in
                        favoriteRow(item)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }

    private var emptyFavoritesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "star")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(homeMenuSelection.tint)
                    .frame(width: 48, height: 48)
                    .background(
                        homeMenuSelection.tint.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )

                Text("Tocca l'icona a stella su un canale, un film o una serie per aggiungerlo qui.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func favoriteRow(_ item: FavoriteItem) -> some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: homeMenuSelection.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(homeMenuSelection.tint)
                    .frame(width: 44, height: 44)
                    .background(
                        homeMenuSelection.tint.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("Aggiunto il \(item.addedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    withAnimation(.snappy) {
                        contentManagement.toggleFavorite(
                            id: item.id,
                            title: item.title,
                            kind: item.kind
                        )
                    }
                } label: {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rimuovi dai preferiti")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                Picker("Sezione Home", selection: $homeMenuSelection) {
                    ForEach(HomeMenuSelection.allCases, id: \.self) { selection in
                        Label(selection.title, systemImage: selection.systemImage)
                            .tag(selection)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                homeMenuPillLabel
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Sezione Home: \(homeMenuSelection.title)")
            .accessibilityHint("Tocca per mostrare la panoramica o i preferiti di Live TV, VOD e Serie TV")
        }

        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSearchButton()
            }

            ToolbarSpacer(.fixed, placement: .navigationBarTrailing)

            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSettingsButton()
            }
        } else {
            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSearchButton()
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSettingsButton()
            }
        }
    }

    /// Pillola "Liquid Glass" per il menu Home.
    ///
    /// FIX MANIACALE: prima questa proprietà costruiva la pillola inline,
    /// duplicando esattamente lo stesso codice che serviva anche a
    /// `SourcesView` per il proprio "floating tab" di ordinamento. Codice
    /// duplicato in due file significa che una modifica futura fatta in un
    /// solo posto li fa divergere silenziosamente (esattamente il tipo di
    /// bug "l'aspetto non è più esattamente lo stesso" che ha causato
    /// questa richiesta). Ora entrambe le viste chiamano lo stesso identico
    /// componente `GlassMenuPillLabel` (definito in `GlassListStyle.swift`):
    /// un'unica fonte di verità per il "floating tab" Liquid Glass di tutta
    /// l'app.
    @ViewBuilder
    private var homeMenuPillLabel: some View {
        GlassMenuPillLabel(
            systemImage: homeMenuSelection.systemImage,
            title: homeMenuSelection.title,
            tint: homeMenuSelection.tint
        )
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tutto il tuo intrattenimento")
                .font(.title2.bold())

            Text(
                hasActiveSource
                    ? "Scegli cosa guardare dalla sorgente attiva."
                    : "Configura una sorgente dalle Impostazioni quando vuoi."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var emptySourceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "sparkles.tv.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 48, height: 48)
                        .background(
                            Color.accentColor.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inizia quando vuoi")
                            .font(.headline)
                        Text("Nessuna sorgente configurata")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Text(
                    "Aggiungi una playlist M3U o un account supportato dalle Impostazioni. Live TV, VOD e Serie TV saranno disponibili appena la sorgente sarà attiva."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                GlassPrimaryButton(
                    title: "Aggiungi sorgente",
                    systemImage: "plus"
                ) {
                    overlayState.showSettings = true
                }
                .accessibilityHint("Apre le Impostazioni per configurare una sorgente")
            }
        }
    }

    private var connectedSourceCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sorgente pronta")
                        .font(.headline)
                    Text(sourceManager.activeSource?.name ?? "Sorgente attiva")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if sourceManager.sources.count > 1 {
                    Menu {
                        Picker("Sorgente attiva", selection: activeSourceSelection) {
                            ForEach(sourceManager.sources) { source in
                                Label(source.name, systemImage: source.type.systemImage)
                                    .tag(source.id as UUID?)
                            }
                        }
                    } label: {
                        // FIX — "arrow.triangle.2.circlepath" richiama uno
                        // "aggiorna/sincronizza", fuorviante per un Menu che
                        // in realtà fa scegliere la sorgente attiva da un
                        // elenco: "chevron.up.chevron.down" è l'icona
                        // standard di un selettore/picker, molto più
                        // coerente con l'azione reale del pulsante.
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Cambia sorgente attiva")
                }

                Button("Gestisci") {
                    if sourceManager.activeSource != nil {
                        showManageActiveSource = true
                    } else {
                        overlayState.showSettings = true
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    /// Binding usato dal menu "Cambia sorgente attiva": aggiorna
    /// direttamente `SourceManager` così l'utente non deve passare da
    /// Impostazioni per cambiare la sorgente in uso.
    private var activeSourceSelection: Binding<UUID?> {
        Binding(
            get: { sourceManager.activeSourceId },
            set: { newValue in
                guard let newValue,
                      let source = sourceManager.sources.first(where: { $0.id == newValue }) else {
                    return
                }

                sourceManager.setActive(source)
            }
        )
    }

    private func libraryDestination(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        destination: MainTab
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Apri") { selectedTab = destination }
                    .font(.subheadline.weight(.semibold))
            }

            Button {
                selectedTab = destination
            } label: {
                GlassCard {
                    HStack(spacing: 14) {
                        Image(systemName: systemImage)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(tint)
                            .frame(width: 50, height: 50)
                            .background(
                                tint.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(subtitle)
        }
    }

    /// Riquadro "Guida TV", identico nell'aspetto a `libraryDestination`
    /// (stesso `GlassCard`, stessa geometria e stesso stile del testo), ma
    /// apre la guida programmi (`EPGGridView`) invece di cambiare tab,
    /// perché la Guida TV non è una destinazione della tab bar.
    private var guidaTVDestination: some View {
        let subtitle = guidaTVSubtitle

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Guida TV")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Apri") { openGuidaTV() }
                    .font(.subheadline.weight(.semibold))
            }

            Button {
                openGuidaTV()
            } label: {
                GlassCard {
                    HStack(spacing: 14) {
                        Image(systemName: "list.bullet.rectangle.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 50, height: 50)
                            .background(
                                Color.orange.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Guida TV")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Guida TV")
            .accessibilityHint(subtitle)
        }
    }

    private var guidaTVSubtitle: String {
        guard hasActiveSource else { return "Disponibile con una sorgente Xtream" }
        guard sourceManager.activeSource?.xtreamCredentials != nil else {
            return "Richiede una sorgente Xtream attiva"
        }

        return epgManager.autoUpdateEnabled
            ? "Programmi e orari · Aggiornamento automatico attivo"
            : "Programmi e orari dei canali Live TV"
    }

    private func openGuidaTV() {
        if sourceManager.activeSource?.xtreamCredentials != nil {
            showGuidaTV = true
        } else {
            showGuidaTVUnavailableAlert = true
        }
    }

    private var onDemandSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On demand")
                .font(.title3.weight(.semibold))

            HStack(spacing: 12) {
                compactDestination(
                    title: "VOD",
                    subtitle: hasActiveSource ? "Film e contenuti on demand" : "Disponibile con una sorgente",
                    systemImage: "film.fill",
                    tint: .purple,
                    destination: .vod
                )

                compactDestination(
                    title: "Serie TV",
                    subtitle: hasActiveSource ? "Scopri le tue serie" : "Disponibile con una sorgente",
                    systemImage: "rectangle.stack.fill",
                    tint: .blue,
                    destination: .series
                )
            }
        }
    }

    private func compactDestination(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        destination: MainTab
    ) -> some View {
        Button {
            selectedTab = destination
        } label: {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 42, height: 42)
                        .background(
                            tint.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )

                    Spacer(minLength: 8)

                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private var sourceSummary: some View {
        Button {
            overlayState.showSources = true
        } label: {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.blue)
                        .frame(width: 38, height: 38)
                        .background(
                            Color.blue.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sorgenti")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(
                            sourceManager.sources.isEmpty
                                ? "Nessuna sorgente configurata"
                                : "\(sourceManager.sources.count) sorgenti configurate"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                // FIX — la scheda "Sorgenti" era già avvolta in un Button,
                // ma senza un contentShape esplicito le zone dell'HStack
                // senza contenuto visibile (es. lo spazio tra il testo e il
                // chevron) potevano non rispondere al tocco. Ora l'intera
                // riga, bordo a bordo, è cliccabile.
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sorgenti")
        .accessibilityHint("Apre l'elenco delle sorgenti configurate")
    }

    private var background: some View {
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
    }
}

struct EmptyLibraryView: View {
    let kind: XtreamStreamKind
    let title: String
    let message: String

    @EnvironmentObject private var overlayState: NavigationOverlayState

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer()

                Image(systemName: kind.systemImage)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 96, height: 96)
                    .background(.thinMaterial, in: Circle())

                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                GlassPrimaryButton(
                    title: "Aggiungi sorgente",
                    systemImage: "plus"
                ) {
                    overlayState.showSettings = true
                }

                Spacer()
            }
            .padding()
            .navigationTitle(kind.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbarContent
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSearchButton()
            }

            ToolbarSpacer(.fixed, placement: .navigationBarTrailing)

            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSettingsButton()
            }
        } else {
            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSearchButton()
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSettingsButton()
            }
        }
    }
}
