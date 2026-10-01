import SwiftUI
import UIKit
import ImageIO
import CryptoKit

// MARK: - Normalizzazione URL immagini

/// Rende utilizzabili gli URL di icone/poster così come arrivano dai provider.
///
/// Causa principale delle icone "che ci sono ma non si vedono": molti
/// pannelli Xtream/M3U inviano URL con spazi o caratteri non ASCII nel
/// percorso, il letterale `"null"`, URL senza schema (`//host/img.png`,
/// `host/img.png`) o con backslash. `URL(string:)` restituisce `nil` (o un
/// URL inutilizzabile) per questi casi e la cella restava col segnaposto
/// per sempre, senza nemmeno tentare il download.
enum ImageURLNormalizer {
    /// Caratteri che possono restare così come sono in un URL già composto
    /// (incluso `%`, per non ricodificare sequenze già codificate).
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "!#$&'()*+,-./:;=?@[]_~%")
        return set
    }()

    private static let placeholders: Set<String> = ["null", "none", "nil", "n/a", "na", "undefined", "false", "0", "-"]

    /// Stringa pulita (o `nil` se il valore non è un URL immagine plausibile).
    static func normalizedString(_ raw: String?) -> String? {
        url(from: raw)?.absoluteString
    }

    static func url(from raw: String?) -> URL? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        // Alcuni provider racchiudono l'URL tra virgolette o lo inviano
        // con le barre "escapate" (`https:\/\/host\/img.png`).
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        value = value.replacingOccurrences(of: "\\/", with: "/")
        value = value.replacingOccurrences(of: "\\", with: "/")
        guard !value.isEmpty, !placeholders.contains(value.lowercased()) else { return nil }

        if value.hasPrefix("//") {
            value = "https:" + value
        } else if !value.contains("://") {
            // "host.tld/percorso/img.png" senza schema. I percorsi relativi
            // ("/img.png", "img.png") non sono risolvibili senza un host.
            guard let first = value.split(separator: "/").first, first.contains("."), !value.hasPrefix("/") else {
                return nil
            }
            value = "http://" + value
        }

        if let url = validURL(value) { return url }

        if let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
           let url = validURL(encoded) {
            return url
        }
        return nil
    }

    private static func validURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }
}

// MARK: - Limitatore di concorrenza (LIFO)

/// Limita i download simultanei. A differenza di un semaforo FIFO serve per
/// prime le richieste PIÙ RECENTI: durante uno scroll veloce sono quelle
/// delle celle ancora visibili, non quelle già uscite dallo schermo.
private actor DownloadLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.popLast() {
            next.resume() // lo slot passa direttamente al prossimo
        } else {
            running -= 1
        }
    }
}

// MARK: - Image loader

/// Caricatore immagini condiviso per icone canali, poster e copertine.
///
/// - cache in memoria di immagini GIÀ decodificate e ridimensionate alla
///   dimensione di visualizzazione (accesso sincrono: una cella ricreata
///   dalla `LazyVGrid` mostra subito l'immagine finale, senza sfarfallio);
/// - cache su disco dei dati originali (sopravvive ai riavvii: le icone già
///   viste compaiono all'istante, senza rete);
/// - richieste identiche unificate (una sola per URL+dimensione);
/// - download saltati se nel frattempo la cella è uscita dallo schermo;
/// - tentativi ripetuti con attesa crescente sugli errori temporanei;
/// - decodifica con ImageIO direttamente alla dimensione necessaria (niente
///   bitmap da 2000 px per una cella da 100 pt).
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private final class Pending: @unchecked Sendable {
        var interest = 1
        var task: Task<UIImage?, Never>?
    }

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let diskDirectory: URL
    private let limiter = DownloadLimiter(limit: 8)
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    /// Esito negativo recente: URL → (scadenza). Evita di martellare host
    /// che rispondono 404, ma consente di riprovare presto dopo un errore di rete.
    private var failures: [String: Date] = [:]

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    private init() {
        memory.countLimit = 1500
        memory.totalCostLimit = 160 * 1024 * 1024

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil // la cache è gestita qui, su disco
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskDirectory = base.appendingPathComponent("GassImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.trimDiskCache(maxBytes: 400 * 1024 * 1024, targetBytes: 280 * 1024 * 1024)
        }
    }

    // MARK: API pubblica

    /// Lato massimo in pixel, arrotondato a multipli di 64 così celle di
    /// dimensioni quasi uguali condividono la stessa immagine in cache.
    static func pixelBucket(points: CGFloat, scale: CGFloat) -> Int {
        let pixels = max(points, 1) * max(scale, 1)
        return Int((pixels / 64).rounded(.up)) * 64
    }

    /// Accesso sincrono alla sola cache in memoria.
    func cachedImage(for url: URL, maxPixel: Int) -> UIImage? {
        memory.object(forKey: Self.memoryKey(url, maxPixel) as NSString)
    }

    /// Carica (o recupera dalla cache) l'immagine. Se il chiamante viene
    /// cancellato (cella uscita dallo schermo) il download, se non ancora
    /// iniziato, viene saltato.
    func image(for url: URL, maxPixel: Int) async -> UIImage? {
        let key = Self.memoryKey(url, maxPixel)
        if let hit = memory.object(forKey: key as NSString) { return hit }

        let pendingEntry = joinOrStart(key: key, url: url, maxPixel: maxPixel)
        return await withTaskCancellationHandler {
            await pendingEntry.task?.value
        } onCancel: {
            self.leave(key: key, entry: pendingEntry)
        }
    }

    /// Scarica in anticipo (fire-and-forget) una manciata di immagini.
    func prefetch(_ urls: [URL], maxPixel: Int) {
        for url in urls.prefix(40) {
            let key = Self.memoryKey(url, maxPixel)
            if memory.object(forKey: key as NSString) != nil { continue }
            _ = joinOrStart(key: key, url: url, maxPixel: maxPixel)
        }
    }

    // MARK: Coordinamento richieste

    private func joinOrStart(key: String, url: URL, maxPixel: Int) -> Pending {
        lock.lock()
        defer { lock.unlock() }

        if let existing = pending[key] {
            existing.interest += 1
            return existing
        }

        let entry = Pending()
        pending[key] = entry
        entry.task = Task.detached(priority: .userInitiated) { [weak self, entry] in
            guard let self else { return nil }
            let image = await self.fetch(url: url, maxPixel: maxPixel, key: key, entry: entry)
            self.finish(key: key)
            return image
        }
        return entry
    }

    private func leave(key: String, entry: Pending) {
        lock.lock()
        entry.interest -= 1
        lock.unlock()
    }

    private func finish(key: String) {
        lock.lock()
        pending[key] = nil
        lock.unlock()
    }

    private func isStale(_ entry: Pending) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entry.interest <= 0
    }

    // MARK: Recupero

    private func fetch(url: URL, maxPixel: Int, key: String, entry: Pending) async -> UIImage? {
        let urlKey = url.absoluteString

        // 1) Disco
        if let data = readFromDisk(url), let image = Self.decode(data, maxPixel: maxPixel) {
            store(image, key: key)
            return image
        }

        // 2) Esito negativo recente
        if let until = failureExpiry(urlKey), until > Date() { return nil }

        // 3) Rete, con limite di concorrenza e tentativi ripetuti
        await limiter.acquire()
        defer { Task { await limiter.release() } }

        // La cella potrebbe essere uscita dallo schermo durante l'attesa.
        if isStale(entry) { return nil }

        var attempt = 0
        while attempt < 3 {
            attempt += 1

            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/webp,image/png,image/jpeg,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200

                if (200..<300).contains(status), !data.isEmpty {
                    if let image = Self.decode(data, maxPixel: maxPixel) {
                        writeToDisk(data, for: url)
                        clearFailure(urlKey)
                        store(image, key: key)
                        return image
                    }
                    // 200 ma non è un'immagine (pagina di errore, HTML...).
                    recordFailure(urlKey, seconds: 600)
                    return nil
                }

                if status == 404 || status == 410 || status == 403 || status == 401 {
                    recordFailure(urlKey, seconds: 600)
                    return nil
                }
                // 429 / 5xx: temporaneo, si riprova.
            } catch {
                if Task.isCancelled { return nil }
                if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
            }

            if attempt < 3 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
                if isStale(entry) { return nil }
            }
        }

        recordFailure(urlKey, seconds: 6)
        return nil
    }

    // MARK: Cache memoria / esiti negativi

    private static func memoryKey(_ url: URL, _ maxPixel: Int) -> String {
        "\(url.absoluteString)#\(maxPixel)"
    }

    private func store(_ image: UIImage, key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func failureExpiry(_ key: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return failures[key]
    }

    private func recordFailure(_ key: String, seconds: TimeInterval) {
        lock.lock()
        if failures.count > 5000 { failures.removeAll() }
        failures[key] = Date().addingTimeInterval(seconds)
        lock.unlock()
    }

    private func clearFailure(_ key: String) {
        lock.lock()
        failures[key] = nil
        lock.unlock()
    }

    // MARK: Cache disco

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private func readFromDisk(_ url: URL) -> Data? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), !data.isEmpty else { return nil }
        // Segna l'uso recente (serve alla pulizia "meno usati per primi").
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    private func writeToDisk(_ data: Data, for url: URL) {
        try? data.write(to: fileURL(for: url), options: .atomic)
    }

    private func trimDiskCache(maxBytes: Int, targetBytes: Int) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? manager.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, date: Date, size: Int)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }

        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }

        entries.sort { $0.date < $1.date }
        for entry in entries {
            if total <= targetBytes { break }
            try? manager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: Decodifica

    /// Decodifica con ImageIO alla dimensione richiesta (mai ingrandendo).
    static func decode(_ data: Data, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        var originalMax = 0
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            originalMax = max(width, height)
        }

        let cgImage: CGImage?
        if originalMax > 0, originalMax <= maxPixel {
            cgImage = CGImageSourceCreateImageAtIndex(
                source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            )
        } else {
            cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                ] as CFDictionary
            )
        }

        guard let cgImage else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - CachedAsyncImage

/// Sostituto di `AsyncImage` per griglie e liste.
///
/// Differenze chiave:
/// - se l'immagine è già in cache la mostra al primo frame (nessun
///   segnaposto intermedio quando la cella viene ricreata);
/// - gli URL vengono normalizzati prima dell'uso;
/// - se il download fallisce riprova da solo finché la cella è visibile;
/// - la cancellazione (scroll) non viene scambiata per un errore.
struct CachedAsyncImage<Placeholder: View>: View {
    private let url: URL?
    private let points: CGSize
    private let contentMode: ContentMode
    private let fixedMaxPixel: Int?
    private let fallback: AnyView?
    private let onLoaded: (() -> Void)?
    private let placeholder: Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var displayedKey: String?
    /// `true` dopo il secondo tentativo andato a vuoto: da qui si mostra
    /// `fallback` (es. segnaposto con iniziali) al posto del `placeholder`
    /// neutro di caricamento, così non c'è mai uno scambio "segnaposto
    /// colorato → immagine" durante il normale caricamento.
    @State private var didFail = false

    /// - `placeholder`: mostrato MENTRE l'immagine si carica (neutro).
    /// - `fallback`: mostrato se non c'è un URL valido o il caricamento è
    ///   fallito in modo definitivo (icona/segnaposto "vero", mai vuoto).
    /// - `onLoaded`: chiamato quando l'immagine è stata mostrata.
    init(
        url: URL?,
        size: CGSize,
        contentMode: ContentMode = .fill,
        maxPixel: Int? = nil,
        fallback: AnyView? = nil,
        onLoaded: (() -> Void)? = nil,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.url = url
        self.points = size
        self.contentMode = contentMode
        self.fixedMaxPixel = maxPixel
        self.fallback = fallback
        self.onLoaded = onLoaded
        self.placeholder = placeholder()

        // Primo frame già corretto se l'immagine è in cache. Si usa la scala
        // dello schermo principale: l'ambiente non è ancora disponibile qui.
        let scale = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 3
        if let url {
            let bucket = maxPixel ?? ImageLoader.pixelBucket(points: max(size.width, size.height), scale: scale)
            if let cached = ImageLoader.shared.cachedImage(for: url, maxPixel: bucket) {
                _image = State(initialValue: cached)
                _displayedKey = State(initialValue: url.absoluteString)
            }
        }
    }

    private var maxPixel: Int {
        fixedMaxPixel ?? ImageLoader.pixelBucket(points: max(points.width, points.height), scale: displayScale)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let fallback, url == nil || didFail {
                fallback
            } else {
                placeholder
            }
        }
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        guard let url else {
            image = nil
            displayedKey = nil
            didFail = false
            return
        }

        let key = url.absoluteString
        let pixels = maxPixel

        if let cached = ImageLoader.shared.cachedImage(for: url, maxPixel: pixels) {
            image = cached
            displayedKey = key
            didFail = false
            onLoaded?()
            return
        }

        // Un'altra immagine era mostrata per un URL diverso: torna al segnaposto.
        if displayedKey != key {
            image = nil
            displayedKey = nil
        }
        didFail = false

        // Tentativi con pause crescenti finché la cella resta visibile. La
        // prima pausa è breve: un `nil` può essere solo una richiesta
        // annullata da un'altra cella che condivideva lo stesso download.
        let pauses: [UInt64] = [500_000_000, 3_000_000_000, 8_000_000_000]
        for round in 0...pauses.count {
            if let loaded = await ImageLoader.shared.image(for: url, maxPixel: pixels) {
                if Task.isCancelled { return }
                image = loaded
                displayedKey = key
                didFail = false
                onLoaded?()
                return
            }
            if Task.isCancelled { return }
            if round >= 1 { didFail = true }
            if round < pauses.count {
                try? await Task.sleep(nanoseconds: pauses[round])
                if Task.isCancelled { return }
            }
        }
    }
}

extension CachedAsyncImage where Placeholder == Color {
    init(
        url: URL?,
        size: CGSize,
        contentMode: ContentMode = .fill,
        maxPixel: Int? = nil,
        fallback: AnyView? = nil,
        onLoaded: (() -> Void)? = nil
    ) {
        self.init(
            url: url,
            size: size,
            contentMode: contentMode,
            maxPixel: maxPixel,
            fallback: fallback,
            onLoaded: onLoaded
        ) { Color.clear }
    }
}

// MARK: - Segnaposto con iniziali

/// Segnaposto "vero" per canali, film e serie senza immagine (URL assente,
/// non valido o irraggiungibile): sfondo sfumato dal colore stabile per
/// titolo, iniziali e piccolo glifo del tipo di contenuto. Nessuna cella
/// resta mai vuota o con un riquadro grigio generico.
struct ArtworkPlaceholder: View {
    let title: String
    let systemImage: String
    var cornerRadius: CGFloat = 12

    /// Hash djb2 stabile tra un avvio e l'altro (`hashValue` di `String` è
    /// casuale ad ogni lancio e cambierebbe i colori ogni volta).
    private var hue: Double {
        var hash: UInt64 = 5381
        for scalar in title.unicodeScalars { hash = (hash &* 33) &+ UInt64(scalar.value) }
        return Double(hash % 360) / 360.0
    }

    private var initials: String {
        let cleaned = TMDBService.cleanedQuery(from: title)
        let source = cleaned.isEmpty ? title : cleaned
        let letters = source
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap { $0.first }
        return String(letters).uppercased()
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)

            ZStack {
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.50, brightness: 0.46),
                        Color(hue: hue, saturation: 0.60, brightness: 0.24)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: side * 0.05) {
                    if !initials.isEmpty {
                        Text(initials)
                            .font(.system(size: side * 0.30, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    Image(systemName: systemImage)
                        .font(.system(size: side * (initials.isEmpty ? 0.28 : 0.13), weight: .semibold))
                        .foregroundStyle(.white.opacity(initials.isEmpty ? 0.8 : 0.55))
                }
                .padding(side * 0.08)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Prefetch delle locandine nelle griglie

/// Scalda le cache (risultati TMDB + immagini) per le celle che stanno per
/// entrare nello schermo: durante lo scroll trovano già tutto pronto e non
/// passano dal segnaposto al poster davanti all'utente.
enum ArtworkPrefetcher {
    struct Entry {
        let title: String
        let iconURLString: String?
    }

    /// `points`/`scale` devono coincidere con quelli della cella, così la
    /// chiave di cache è identica a quella che la cella andrà a leggere.
    static func prefetch(_ entries: [Entry], isSeries: Bool, points: CGSize, scale: CGFloat, resolveTMDB: Bool) {
        guard !entries.isEmpty else { return }

        let bucket = ImageLoader.pixelBucket(points: max(points.width, points.height), scale: scale)
        let useTMDB = resolveTMDB && TMDBService.hasAPIKey

        var imageURLs: [URL] = []
        var pendingLookups: [String] = []

        for entry in entries {
            if useTMDB {
                if let cached = TMDBService.cachedResult(title: entry.title, isSeries: isSeries),
                   let poster = cached.posterURL {
                    imageURLs.append(poster)
                    continue
                }
                if !TMDBService.isKnownMiss(title: entry.title, isSeries: isSeries) {
                    pendingLookups.append(entry.title)
                }
            }
            if let url = ImageURLNormalizer.url(from: entry.iconURLString) {
                imageURLs.append(url)
            }
        }

        ImageLoader.shared.prefetch(imageURLs, maxPixel: bucket)

        guard !pendingLookups.isEmpty else { return }
        let lookups = Array(pendingLookups.prefix(24))
        Task.detached(priority: .utility) {
            // Le richieste identiche sono unificate e le simultanee limitate
            // da `TMDBService` (4 alla volta): qui si possono accodare tutte.
            await withTaskGroup(of: Void.self) { group in
                for title in lookups {
                    group.addTask {
                        if Task.isCancelled { return }
                        if let result = try? await TMDBService.shared.lookup(title: title, isSeries: isSeries),
                           let poster = result.posterURL {
                            ImageLoader.shared.prefetch([poster], maxPixel: bucket)
                        }
                    }
                }
            }
        }
    }
}
