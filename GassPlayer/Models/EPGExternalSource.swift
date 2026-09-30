import Foundation

/// Fonte EPG esterna in formato XMLTV, aggiunta manualmente dall'utente
/// dalla schermata "Gestisci guida TV" (voce "Aggiungi fonte EPG").
/// Utile soprattutto per arricchire playlist M3U prive di una guida
/// programmi integrata, o per affiancare una guida di terze parti a quella
/// già fornita da una sorgente Xtream.
struct EPGExternalSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var urlString: String
    var isEnabled: Bool = true
    var addedAt: Date = Date()

    /// URL http/https valido costruito da `urlString`, `nil` se il testo
    /// salvato non è (più) un URL utilizzabile.
    var url: URL? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }
        return url
    }

    init(
        id: UUID = UUID(),
        name: String,
        urlString: String,
        isEnabled: Bool = true,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.isEnabled = isEnabled
        self.addedAt = addedAt
    }

    // Init manuale per restare tollerante a eventuali campi mancanti in
    // futuro, seguendo la stessa convenzione di `MediaSourceConfig`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        urlString = try container.decode(String.self, forKey: .urlString)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }
}
