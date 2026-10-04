import Foundation

/// Decompressione gzip (RFC 1952) senza dipendenze: legge l'intestazione,
/// salta i campi opzionali e inflata il flusso DEFLATE con `NSData`.
/// Serve per le guide XMLTV `.xml.gz` (le playlist/EPG servite con
/// `Content-Encoding: gzip` le decomprime già `URLSession`; qui si gestiscono
/// i file che sono gzip "veri", con estensione `.gz`).
enum GzipDecoder {
    static func isGzip(_ data: Data) -> Bool {
        data.count > 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    static func decompress(_ data: Data) -> Data? {
        guard isGzip(data) else { return nil }

        let base = data.startIndex
        let flags = data[base + 3]
        var offset = 10

        if flags & 0x04 != 0 { // FEXTRA
            guard data.count > offset + 2 else { return nil }
            let length = Int(data[base + offset]) | (Int(data[base + offset + 1]) << 8)
            offset += 2 + length
        }

        if flags & 0x08 != 0 { // FNAME
            while offset < data.count, data[base + offset] != 0 { offset += 1 }
            offset += 1
        }

        if flags & 0x10 != 0 { // FCOMMENT
            while offset < data.count, data[base + offset] != 0 { offset += 1 }
            offset += 1
        }

        if flags & 0x02 != 0 { offset += 2 } // FHCRC

        // Gli ultimi 8 byte sono CRC32 + dimensione originale.
        guard offset < data.count - 8 else { return nil }

        let body = data.subdata(in: (base + offset)..<(data.endIndex - 8))

        do {
            return try (body as NSData).decompressed(using: .zlib) as Data
        } catch {
            return nil
        }
    }

    /// Restituisce i byte decompressi se `data` è gzip, altrimenti `data`.
    static func decompressedIfNeeded(_ data: Data) -> Data {
        guard isGzip(data) else { return data }
        return decompress(data) ?? data
    }
}
