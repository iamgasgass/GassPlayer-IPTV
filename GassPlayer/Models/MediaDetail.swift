import Foundation

/// Un membro del cast mostrato nella sezione "CAST": con foto quando i dati
/// vengono da TMDB, senza foto (solo iniziale) quando vengono dal solo
/// campo testuale "cast" del provider Xtream.
struct MediaCastMember: Identifiable, Hashable {
    let id: String
    let name: String
    let role: String?
    let photoURL: URL?
}

/// Tutte le fonti di voto mostrate nella sezione "VALUTAZIONI" del video
/// dimostrativo. Ogni campo è opzionale e indipendente dagli altri: la
/// sezione mostra solo le fonti effettivamente disponibili (nessuna API
/// key configurata → nessun errore, semplicemente quella fonte non compare).
struct MediaRatings: Equatable {
    var tmdbPercent: Int?
    var traktPercent: Int?
    var imdbScore: Double?
    var rottenTomatoesPercent: Int?
    var metacriticScore: Int?

    var isEmpty: Bool {
        tmdbPercent == nil && traktPercent == nil && imdbScore == nil
            && rottenTomatoesPercent == nil && metacriticScore == nil
    }
}

/// Scheda dettaglio completa per un film o una serie: quanto serve alla
/// UI "hero" (backdrop, logo, trama, genere, durata/anno, cast, voti),
/// indipendentemente dal fatto che i singoli campi vengano dal provider
/// Xtream, da TMDB, da OMDb o da Trakt.
struct MediaDetail {
    var overview: String?
    var backdropURL: URL?
    var logoURL: URL?
    var posterURL: URL?
    var genres: [String]
    var year: String?
    var runtimeMinutes: Int?
    var cast: [MediaCastMember]
    var ratings: MediaRatings
    var imdbId: String?

    static let empty = MediaDetail(
        overview: nil,
        backdropURL: nil,
        logoURL: nil,
        posterURL: nil,
        genres: [],
        year: nil,
        runtimeMinutes: nil,
        cast: [],
        ratings: MediaRatings(),
        imdbId: nil
    )

    var runtimeLabel: String? {
        guard let runtimeMinutes, runtimeMinutes > 0 else { return nil }
        let hours = runtimeMinutes / 60
        let minutes = runtimeMinutes % 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)min" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)min"
    }
}

/// Punto di partenza noto dal catalogo Xtream (prima di qualunque
/// arricchimento esterno), usato sia come base sia come fallback se TMDB/
/// OMDb/Trakt non sono disponibili o non trovano corrispondenze.
struct MediaDetailSeed {
    let title: String
    let isSeries: Bool
    var overview: String?
    var backdropURLString: String?
    var genreNames: [String]
    var castNames: [String]
    var year: String?
    var runtimeMinutes: Int?
    var xtreamRating: Double?
}

/// Orchestratore che combina Xtream (base), TMDB (cast con foto, loghi,
/// backdrop in alta qualità, voto), OMDb (IMDb/Rotten Tomatoes/Metacritic)
/// e Trakt (voto community): ogni fonte è opzionale e la mancanza di una
/// non blocca le altre. Pensato per essere chiamato una sola volta
/// all'apertura della scheda dettaglio.
enum MediaDetailLoader {
    static func load(_ seed: MediaDetailSeed) async -> MediaDetail {
        var detail = MediaDetail(
            overview: seed.overview,
            backdropURL: seed.backdropURLString.flatMap(URL.init(string:)),
            logoURL: nil,
            posterURL: nil,
            genres: seed.genreNames,
            year: seed.year,
            runtimeMinutes: seed.runtimeMinutes,
            cast: seed.castNames.map {
                MediaCastMember(id: $0, name: $0, role: nil, photoURL: nil)
            },
            ratings: MediaRatings(),
            imdbId: nil
        )

        if seed.xtreamRating.map({ $0 > 0 }) == true {
            // Xtream esprime spesso il rating su base 10: usato solo come
            // riserva, sovrascritto subito sotto se TMDB risponde.
            detail.ratings.tmdbPercent = Int((seed.xtreamRating! * 10).rounded())
        }

        guard TMDBService.hasAPIKey else { return detail }

        guard let tmdb = try? await TMDBService.shared.fullDetails(title: seed.title, isSeries: seed.isSeries) else {
            return detail
        }

        if let overview = tmdb.overview?.nonEmpty { detail.overview = overview }
        if let backdrop = tmdb.backdropURL { detail.backdropURL = backdrop }
        detail.logoURL = tmdb.logoURL
        detail.posterURL = tmdb.posterURL
        if !tmdb.genreNames.isEmpty { detail.genres = tmdb.genreNames }
        if let year = tmdb.year { detail.year = year }
        if let runtime = tmdb.runtimeMinutes, runtime > 0 { detail.runtimeMinutes = runtime }

        let tmdbCast = tmdb.topCast(12).map { member in
            MediaCastMember(
                id: "tmdb-\(member.id)",
                name: member.name,
                role: member.character,
                photoURL: member.profileURL
            )
        }
        if !tmdbCast.isEmpty { detail.cast = tmdbCast }

        if let vote = tmdb.voteAverage, vote > 0 {
            detail.ratings.tmdbPercent = Int((vote * 10).rounded())
        }

        detail.imdbId = tmdb.externalIds?.imdbId?.nonEmpty

        guard let imdbId = detail.imdbId else { return detail }

        if OMDbService.hasAPIKey, let omdb = try? await OMDbService.shared.ratings(imdbId: imdbId) {
            detail.ratings.imdbScore = omdb.imdbRatingValue
            detail.ratings.rottenTomatoesPercent = omdb.rottenTomatoesPercent
            detail.ratings.metacriticScore = omdb.metacriticScore
        }

        let traktClientId = await MainActor.run { TraktAccountManager.shared.clientId }
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !traktClientId.isEmpty {
            let trakt = TraktService(clientId: traktClientId, clientSecret: "")
            if let traktRatings = try? await trakt.ratings(imdbId: imdbId, isSeries: seed.isSeries) {
                detail.ratings.traktPercent = Int((traktRatings.rating * 10).rounded())
            }
        }

        return detail
    }
}
