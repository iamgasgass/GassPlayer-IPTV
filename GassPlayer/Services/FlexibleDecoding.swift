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
    static func decode<T: Decodable>(_ type: [T].Type, from data: Data) -> [T] {
        if let array = try? JSONDecoder().decode([T].self, from: data) {
            return array
        }

        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if let jsonObject = try? JSONSerialization.jsonObject(with: data) {
                if let dict = jsonObject as? [String: Any], dict.isEmpty { return [] }
                if let bool = jsonObject as? Bool, bool == false { return [] }
            }
            return []
        }

        var results: [T] = []
        results.reserveCapacity(rawArray.count)
        var skippedCount = 0
        let decoder = JSONDecoder()

        for element in rawArray {
            guard let itemData = try? JSONSerialization.data(withJSONObject: element),
                  let decoded = try? decoder.decode(T.self, from: itemData) else {
                skippedCount += 1
                continue
            }
            results.append(decoded)
        }

        if skippedCount > 0 {
            DebugLogger.logAsync(.warning, "FlexibleArrayDecoder: \(skippedCount) elementi scartati (campi malformati) su \(rawArray.count) totali durante la decodifica di [\(T.self)] — recuperati correttamente gli altri \(results.count)")
        }

        return results
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
