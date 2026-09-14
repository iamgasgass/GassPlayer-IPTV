import SwiftUI

/// Home principale.
///
/// - Dopo la splash è sempre accessibile, anche senza sorgenti.
/// - I pulsanti contestuali Sorgenti aprono direttamente `SourcesView`.
/// - Ricerca e Impostazioni rimangono azioni toolbar distinte.
/// - Non avvia richieste di rete: SourceManager e ContentView coordinano lo
///   stato della sorgente attiva, mentre le tab del catalogo caricano i dati.
struct HomeView: View {
    @Binding var selectedTab: MainTab
    let hasActiveSource: Bool

    @EnvironmentObject private var sourceManager: SourceManager

    @State private var showSources = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heading

                    if hasActiveSource {
                        activeSourceCard
                    } else {
                        emptySourceCard
                    }

                    liveDestination
                    onDemandSection
                    sourcesSummaryCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(background)
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                toolbarContent
            }
        }
        // SourcesView possiede già una NavigationStack. Non aggiungere una
        // seconda NavigationStack nel contenuto della sheet.
        .sheet(isPresented: $showSources) {
            SourcesView()
        }
    }

    // MARK: - Toolbar

    /// Mantiene Ricerca e Impostazioni come controlli distinti.
    /// ToolbarSpacer è disponibile solo su iOS 26+, quindi resta protetto
    /// dall'availability check; su iOS 17–25 gli item restano separati come
    /// normali ToolbarItem.
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

    // MARK: - Header

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tutto il tuo intrattenimento")
                .font(.title2.bold())

            Text(
                hasActiveSource
                    ? "Scegli cosa guardare dalla sorgente attiva."
                    : "Configura una sorgente quando vuoi."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sorgenti

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
                            in: RoundedRectangle(
                                cornerRadius: 15,
                                style: .continuous
                            )
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inizia quando vuoi")
                            .font(.headline)

                        Text("Nessuna sorgente configurata")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                Text(
                    "Aggiungi una playlist M3U o un account Xtream. Live TV, VOD e Serie TV saranno disponibili appena attivi una sorgente."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                GlassPrimaryButton(
                    title: "Aggiungi sorgente",
                    systemImage: "plus"
                ) {
                    showSources = true
                }
                .accessibilityHint(
                    "Apre l'elenco delle sorgenti. Usa il pulsante più per aggiungerne una."
                )
            }
        }
    }

    private var activeSourceCard: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sorgente pronta")
                        .font(.headline)

                    Text(activeSourceDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button("Gestisci") {
                    showSources = true
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityHint(
                    "Apre l'elenco e la gestione delle sorgenti"
                )
            }
        }
    }

    private var sourcesSummaryCard: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.blue.opacity(0.15),
                        in: RoundedRectangle(
                            cornerRadius: 12,
                            style: .continuous
                        )
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Sorgenti")
                        .font(.subheadline.weight(.medium))

                    Text(sourcesSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button("Gestisci") {
                    showSources = true
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityHint(
                    "Apre l'elenco e la gestione delle sorgenti"
                )
            }
        }
    }

    private var activeSourceDescription: String {
        guard let source = sourceManager.activeSource else {
            return "Sorgente attiva"
        }

        return source.isEnabled
            ? source.name
            : "Sorgente disabilitata"
    }

    private var sourcesSummaryText: String {
        let allSources = sourceManager.sources.count
        let enabledSources = sourceManager.sources.filter(\.isEnabled).count

        switch (allSources, enabledSources) {
        case (0, _):
            return "Nessuna sorgente configurata"
        case (1, 1):
            return "1 sorgente attiva"
        case (1, 0):
            return "1 sorgente disabilitata"
        case (_, 0):
            return "\(allSources) sorgenti, tutte disabilitate"
        default:
            return "\(enabledSources) attive su \(allSources) sorgenti"
        }
    }

    // MARK: - Destinazioni

    private var liveDestination: some View {
        destinationCard(
            title: "Live TV",
            subtitle: hasActiveSource
                ? "Canali in diretta dalla sorgente attiva"
                : "I canali appariranno qui",
            systemImage: "tv.fill",
            tint: .red,
            destination: MainTab.liveTV
        )
    }

    private var onDemandSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On demand")
                .font(.title3.weight(.semibold))

            HStack(spacing: 12) {
                compactDestinationCard(
                    title: "VOD",
                    subtitle: hasActiveSource
                        ? "Film e contenuti on demand"
                        : "Disponibile con una sorgente",
                    systemImage: "film.fill",
                    tint: .purple,
                    destination: MainTab.vod
                )

                compactDestinationCard(
                    title: "Serie TV",
                    subtitle: hasActiveSource
                        ? "Scopri le tue serie"
                        : "Disponibile con una sorgente",
                    systemImage: "rectangle.stack.fill",
                    tint: .blue,
                    destination: MainTab.series
                )
            }
        }
    }

    private func destinationCard(
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

                Button("Apri") {
                    selectedTab = destination
                }
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
                                in: RoundedRectangle(
                                    cornerRadius: 15,
                                    style: .continuous
                                )
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
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

    private func compactDestinationCard(
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
                            in: RoundedRectangle(
                                cornerRadius: 13,
                                style: .continuous
                            )
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
                .frame(
                    maxWidth: .infinity,
                    minHeight: 150,
                    alignment: .leading
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    // MARK: - Styling

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
