import SwiftUI

/// Schermata "TMDB e OMDb": prima di questa vista non esisteva ALCUN modo,
/// nell'app, di inserire una API key TMDB — `TMDBService` era già scritto e
/// funzionante, ma di fatto irraggiungibile. Qui l'utente incolla le
/// proprie chiavi personali gratuite; entrambe restano solo su questo
/// dispositivo (`UserDefaults`), esattamente come per Trakt.tv.
struct MetadataSettingsView: View {
    @AppStorage(TMDBService.apiKeyDefaultsKey)
    private var tmdbAPIKey = ""

    @AppStorage(OMDbService.apiKeyDefaultsKey)
    private var omdbAPIKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                tmdbCard
                omdbCard
                aboutCard
            }
            .padding(20)
        }
        .background(background)
        .navigationTitle("TMDB e OMDb")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tmdbCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: tmdbAPIKey.isEmpty ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(tmdbAPIKey.isEmpty ? .orange : .green)
                Text("TMDB")
                    .font(.headline)
            }

            Text("Necessaria per i poster reali, i loghi dei titoli, il cast con foto e il voto mostrati nelle schede film/serie. Gratuita: registrati su themoviedb.org e genera una API key (v3 auth) dalle impostazioni del tuo account.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            fieldBlock(title: "API key TMDB") {
                TextField("Incolla qui la tua API key", text: $tmdbAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let url = URL(string: "https://www.themoviedb.org/settings/api") {
                Link(destination: url) {
                    Label("Genera una API key TMDB", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var omdbCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: omdbAPIKey.isEmpty ? "circle.dashed" : "checkmark.circle.fill")
                    .foregroundStyle(omdbAPIKey.isEmpty ? Color.secondary : Color.green)
                Text("OMDb (facoltativa)")
                    .font(.headline)
            }

            Text("Aggiunge alla sezione \"Valutazioni\" il voto IMDb, la percentuale Rotten Tomatoes e il punteggio Metacritic. Senza questa chiave la sezione mostra comunque TMDB e, se collegato, Trakt.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            fieldBlock(title: "API key OMDb") {
                TextField("Incolla qui la tua API key", text: $omdbAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let url = URL(string: "https://www.omdbapi.com/apikey.aspx") {
                Link(destination: url) {
                    Label("Genera una API key OMDb", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Come vengono usate")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Le chiavi restano solo su questo dispositivo e vengono usate esclusivamente per interrogare TMDB/OMDb quando apri la scheda di un film o di una serie. Senza alcuna chiave configurata l'app continua a funzionare normalmente, mostrando solo i dati già forniti dalla tua sorgente Xtream.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fieldBlock<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.10),
                Color(uiColor: .systemBackground),
                Color.purple.opacity(0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
