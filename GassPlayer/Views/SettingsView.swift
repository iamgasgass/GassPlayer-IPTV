import SwiftUI

struct SettingsView: View {
    @ObservedObject var catalog: XtreamCatalogStore
    @ObservedObject var settings: CatalogSettings
    let credentials: XtreamCredentials?

    @Environment(\.dismiss) private var dismiss
    @State private var refreshing = false
    @State private var clearing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Catalogo e sincronizzazione") {
                    Picker(
                        "Aggiornamento automatico",
                        selection: $settings.refreshInterval
                    ) {
                        ForEach(
                            CatalogSettings.RefreshInterval.allCases
                        ) { interval in
                            Text(interval.title)
                                .tag(interval)
                        }
                    }

                    Toggle(
                        "Aggiorna all’apertura",
                        isOn: $settings.refreshOnLaunch
                    )

                    if let date = settings.lastRefreshDate {
                        LabeledContent("Ultimo aggiornamento") {
                            Text(
                                date,
                                format: .dateTime
                                    .day()
                                    .month()
                                    .year()
                                    .hour()
                                    .minute()
                            )
                            .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task {
                            await refreshCatalog()
                        }
                    } label: {
                        Label(
                            "Aggiorna ora",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(refreshing || credentials == nil)

                    Button(role: .destructive) {
                        Task {
                            await clearCache()
                        }
                    } label: {
                        Label(
                            "Cancella cache catalogo",
                            systemImage: "trash"
                        )
                    }
                    .disabled(clearing)
                }

                Section("Riproduzione") {
                    Toggle(
                        "Mostra programma corrente",
                        isOn: $settings.showEPGInChannelTiles
                    )

                    Toggle(
                        "Precarica dettagli delle serie",
                        isOn: $settings.preloadSeries
                    )
                }
            }
            .navigationTitle("Impostazioni")
            .toolbar {
                ToolbarItem(
                    placement: .topBarTrailing
                ) {
                    Button("Fine") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func refreshCatalog() async {
        guard let credentials, !refreshing else {
            return
        }

        refreshing = true
        await catalog.refresh(credentials: credentials)
        refreshing = false
    }

    private func clearCache() async {
        guard !clearing else {
            return
        }

        clearing = true
        await catalog.clearPersistedCache(
            credentials: credentials
        )
        clearing = false
    }
}
