import SwiftUI

/// "Gestisci sorgenti": hub dedicato esclusivamente alla gestione delle
/// sorgenti già configurate, raggiunto dalla voce omonima nella sezione
/// "Sorgenti". A differenza di `SourcesView` (che aggiunge, ordina, unisce
/// ed esporta le sorgenti) qui l'unico scopo è entrare rapidamente nella
/// scheda di gestione di una singola sorgente (`SourceManageView`, la stessa
/// aperta da Home tramite "Sorgente pronta" → "Gestisci"), con lo stesso
/// linguaggio visivo Liquid Glass del resto dell'app.
struct SourceManagerView: View {
    @EnvironmentObject private var sourceManager: SourceManager
    @EnvironmentObject private var contentManagement: ContentManagementService
    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore

    @State private var managingSource: MediaSourceConfig?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sourceManager.sources.isEmpty {
                    emptyState
                } else {
                    Text("Tocca una sorgente per ricaricarla, modificarne i dettagli, gestirne il contenuto o la guida EPG.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    GlassCard(padding: 6) {
                        VStack(spacing: 0) {
                            ForEach(Array(sourceManager.sources.enumerated()), id: \.element.id) { index, source in
                                if index > 0 {
                                    GlassRowDivider(leading: 66)
                                }

                                sourceRow(source)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(background)
        .navigationTitle("Gestisci sorgenti")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $managingSource) { source in
            SourceManageView(source: source)
                .environmentObject(sourceManager)
                .environmentObject(contentManagement)
                .environmentObject(xtreamCatalog)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nessuna sorgente configurata",
            systemImage: "square.stack.3d.up",
            description: Text("Torna alle Sorgenti e tocca \u{201C}Aggiungi playlist\u{201D} per iniziare.")
        )
        .listRowBackground(Color.clear)
    }

    private func sourceRow(_ source: MediaSourceConfig) -> some View {
        Button {
            managingSource = source
        } label: {
            HStack(spacing: 14) {
                Image(systemName: source.iconName ?? source.type.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(rowTint(for: source))
                    .frame(width: 44, height: 44)
                    .background(rowTint(for: source).opacity(0.16), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if source.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Text(source.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }

                    Text(source.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(source.type.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                if sourceManager.activeSourceId == source.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Sorgente attiva")
                }

                Circle()
                    .fill(source.isEnabled ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(source.name)
        .accessibilityHint("Apri la gestione di questa sorgente")
    }

    private func rowTint(for source: MediaSourceConfig) -> Color {
        switch source.type {
        case .xtream: return .orange
        case .m3u8: return .blue
        case .plex: return .yellow
        case .jellyfin: return .purple
        case .emby: return .green
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.08),
                Color(uiColor: .systemBackground)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
