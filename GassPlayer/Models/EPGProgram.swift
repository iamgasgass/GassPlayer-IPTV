import Foundation

/// Rappresenta un singolo programma della guida elettronica (EPG) per un
/// canale Xtream. Il modello e' intenzionalmente indipendente dal formato
/// del provider: la conversione da payload grezzo avviene in `EPGService`.
struct EPGProgram: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let description: String?
    let start: Date
    let end: Date
    let hasArchive: Bool

    /// Durata del programma in secondi. Sempre >= 0 per costruzione,
    /// perche' `EPGService` scarta gli intervalli non validi (end <= start).
    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }

    /// Percentuale di avanzamento (0...1) rispetto a un istante dato.
    /// Utile per barre di progresso nella guida e nei tile canale.
    func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else {
            return 0
        }

        let elapsed = date.timeIntervalSince(start)
        return min(max(elapsed / duration, 0), 1)
    }

    /// Vero se `date` cade nell'intervallo [start, end).
    func isCurrent(at date: Date = Date()) -> Bool {
        start <= date && end > date
    }

    /// Vero se il programma e' interamente nel futuro rispetto a `date`.
    func isUpcoming(at date: Date = Date()) -> Bool {
        start > date
    }
}
