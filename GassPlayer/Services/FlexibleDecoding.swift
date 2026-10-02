import Foundation

enum FlexibleArrayDecoder {
    /// FIX "la lista si interrompe a meta'": JSONDecoder().decode([T].self)
    /// e' tutto-o-niente su un array — se anche un solo elemento fallisce
    /// (campo malformato, tipo inatteso), l'INTERA decodifica fallisce e si
    /// perdono tutti gli elementi, non solo quello problematico. Con
    /// risposte Xtream reali di centinaia o migliaia di VOD, un singolo
    /// campo anomalo in una posizione qualunque troncava silenziosamente
    /// l'intera lista.
    ///
    /// Fix: si prova prima la via veloce (decodifica dell'intero array in
    /// un colpo, che funziona per risposte pulite). Se fallisce, si passa
    /// a una decodifica elemento per elemento: ogni voce viene decodificata
    /// singolarmente, e solo quelle davvero malformate vengono scartate —
    /// tutte le altre, anche se nello stesso array di una voce "cattiva",
    /// vengono recuperate correttamente.
    ///
    /// (Storico: fino al 2026-09-20 il recupero girava in parallelo con
    /// `concurrentPerform`; vedi sotto la versione a passata singola.)
    ///
    /// OTTIMIZZAZIONE 2026-10-02 (ricezione playlist più efficiente):
    /// 1) Il recupero elemento-per-elemento non passa più da
    /// `JSONSerialization` → `Data` → `JSONDecoder` PER OGNI VOCE (due
    /// serializzazioni complete del catalogo, solo per scartare 1-2
    /// elementi malformati — caso frequentissimo: anche un solo `stream_id`
    /// mancante faceva fallire la via veloce). Ora la via di recupero è una
    /// SECONDA decodifica singola dello stesso `Data` con `LossyElement`,
    /// un wrapper che non fallisce mai e quindi consuma ogni voce
    /// scartando solo quelle davvero illeggibili: stesso risultato, stesso
    /// ordine, senza alcuna re-serializzazione.
    /// 2) Alcuni pannelli restituiscono, invece di un array, un OGGETTO
    /// indicizzato (`{"1": {...}, "2": {...}}`): prima il catalogo
    /// risultava vuoto, ora i valori vengono letti in ordine di chiave.
    static func decode<T: Decodable>(_ type: [T].Type, from data: Data) -> [T] {
        if let array = try? JSONDecoder().decode([T].self, from: data) {
            return array
        }

        if let lossy = try? JSONDecoder().decode([LossyElement<T>].self, from: data) {
            let results = lossy.compactMap(\.value)
            let skippedCount = lossy.count - results.count

            if skippedCount > 0 {
                DebugLogger.logAsync(.warning, "FlexibleArrayDecoder: \(skippedCount) elementi scartati (campi malformati) su \(lossy.count) totali durante la decodifica di [\(T.self)] — recuperati correttamente gli altri \(results.count)")
            }

            return results
        }

        // Radice non-array: oggetto indicizzato, `{}` o `false` (assenza di
        // contenuti per molti pannelli).
        if let indexed = try? JSONDecoder().decode([String: LossyElement<T>].self, from: data) {
            return indexed
                .sorted { lhs, rhs in
                    switch (Int(lhs.key), Int(rhs.key)) {
                    case let (left?, right?): return left < right
                    default: return lhs.key < rhs.key
                    }
                }
                .compactMap { $0.value.value }
        }

        return []
    }

    /// Wrapper che non fallisce mai: se la voce non è decodificabile come
    /// `T` il valore resta `nil`, ma l'elemento viene comunque "consumato"
    /// dal container non tipizzato (indispensabile perché la decodifica
    /// dell'array prosegua con la voce successiva).
    private struct LossyElement<T: Decodable>: Decodable {
        let value: T?

        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }
}

// NOTA: gli helper `decodeFlexibleInt(forKey:)` e `decodeFlexibleString(forKey:)`
// su `KeyedDecodingContainer` sono definiti UNA SOLA VOLTA, in
// `GassPlayer/Models/XtreamModels.swift` (insieme a `decodeFlexibleBool`).
// Non ridichiararli qui: Swift considera equivalenti le firme generiche
// `<K: CodingKey>(forKey key: K)` e quelle dirette `(forKey key: Key)` dopo
// la risoluzione dei generici, quindi una seconda copia in questo file
// produce "invalid redeclaration" in fase di compilazione dell'intero
// modulo GassPlayer.
