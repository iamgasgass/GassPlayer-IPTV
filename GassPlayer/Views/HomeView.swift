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
    @State private var resumeItem: RecentlyWatchedItem?

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
            .sheet(isPresented: $showManageActiveSource) {
                if let activeSource = sourceManager.activeSource {
                    SourceManageView(source: activeSource)
                        .environmentObject(sourceManager)
                        .environmentObject(contentManagement)
                        .environmentObject(xtreamCatalog)
                        .environmentObject(m3uStore)
                }
            }
            .fullScreenCover(item: $resumeItem) { item in
                AdaptivePlayerView(url: item.streamURL, title: item.title)
            }
        }
    }

    // MARK: - Overview

    private var overviewScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heading

                if !recentlyWatched.items.isEmpty {
                    continueWatchingSection
                }

                if hasActiveSource {
                    connectedSourceCard
                } else {
                    emptySourceCard
                }

                libraryDestination(
                    title: "Live TV",
                    subtitle: hasActiveSource
                        ? "Canali in diretta dalla sorgente attiva"
                        : "I canali appariranno qui",
                    systemImage: "tv.fill",
                    tint: .red,
                    destination: .liveTV
                )

                guidaTVDestination

                onDemandSection

                sourceSummary
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Continua a guardare

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Continua a guardare")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Svuota") {
                    withAnimation(.snappy) { recentlyWatched.clear() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentlyWatched.items) { item in
                        continueWatchingCard(item)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func continueWatchingCard(_ item: RecentlyWatchedItem) -> some View {
        Button {
            resumeItem = item
        } label: {
            GlassCard(cornerRadius: 16, padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(continueWatchingTint(item).opacity(0.16))
                            .frame(width: 168, height: 94)

                        Image(systemName: continueWatchingSystemImage(item))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(continueWatchingTint(item))
                            .frame(width: 168, height: 94)

                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, continueWatchingTint(item))
                            .padding(8)
                    }

                    Text(item.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(width: 168, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation(.snappy) { recentlyWatched.remove(item) }
            } label: {
                Label("Rimuovi", systemImage: "trash")
            }
        }
        .accessibilityLabel(item.title)
        .accessibilityHint("Riprendi la riproduzione")
    }

    private func continueWatchingSystemImage(_ item: RecentlyWatchedItem) -> String {
        switch item.kind {
        case XtreamStreamKind.live.rawValue: return "tv.fill"
        case XtreamStreamKind.movie.rawValue: return "film.fill"
        case XtreamStreamKind.series.rawValue: return "rectangle.stack.fill"
        default: return "play.rectangle.fill"
        }
    }

    private func continueWatchingTint(_ item: RecentlyWatchedItem) -> Color {
        switch item.kind {
        case XtreamStreamKind.live.rawValue: return .red
        case XtreamStreamKind.movie.rawValue: return .purple
        case XtreamStreamKind.series.rawValue: return .blue
        default: return .accentColor
        }
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
