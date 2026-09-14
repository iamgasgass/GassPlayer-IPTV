import SwiftUI

struct HomeView: View {
    @Binding var selectedTab: MainTab
    let hasActiveSource: Bool

    @EnvironmentObject private var overlayState: NavigationOverlayState
    @EnvironmentObject private var sourceManager: SourceManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heading

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

                    onDemandSection

                    sourceSummary
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

                Button("Gestisci") {
                    overlayState.showSettings = true
                }
                .font(.subheadline.weight(.semibold))
            }
        }
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
                    Text(
                        sourceManager.sources.isEmpty
                            ? "Nessuna sorgente configurata"
                            : "\(sourceManager.sources.count) sorgenti configurate"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Gestisci") {
                    overlayState.showSettings = true
                }
                .font(.subheadline.weight(.semibold))
            }
        }
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
