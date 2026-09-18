import Foundation
import Combine

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var activeDownloads: [UUID: Double] = [:]

    /// Persistito su `UserDefaults` (prima si azzerava ad ogni riavvio) e
    /// applicato davvero alla sessione di download: prima veniva letto solo
    /// alla primissima creazione della `lazy var session`, quindi cambiare
    /// il toggle dopo il primo download non aveva alcun effetto reale.
    @Published var wifiOnly: Bool {
        didSet {
            guard wifiOnly != oldValue else { return }
            UserDefaults.standard.set(wifiOnly, forKey: Keys.wifiOnly)
            rebuildSessionIfPossible()
        }
    }

    private var session: URLSession?

    private enum Keys {
        static let wifiOnly = "gassplayer.downloads.wifiOnly"
    }

    override init() {
        wifiOnly = UserDefaults.standard.object(forKey: Keys.wifiOnly) as? Bool ?? true
        super.init()
    }

    /// Crea la sessione al primo utilizzo effettivo (non nell'init, per non
    /// aprire una sessione in background inutilizzata) e la riusa finché
    /// `wifiOnly` non cambia.
    private func currentSession() -> URLSession {
        if let session { return session }

        let config = URLSessionConfiguration.background(withIdentifier: "com.iamgasgass.gassPlayer.downloads")
        config.allowsCellularAccess = !wifiOnly
        let newSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = newSession
        return newSession
    }

    /// `URLSessionConfiguration` non è modificabile dopo la creazione della
    /// sessione: per far sì che il toggle "Download solo Wi-Fi" abbia
    /// davvero effetto, la sessione va ricreata con la nuova configurazione.
    /// Se ci sono download in corso si rimanda la ricostruzione a quando
    /// terminano, per non perderli: il nuovo valore si applicherà comunque
    /// al download successivo.
    private func rebuildSessionIfPossible() {
        guard activeDownloads.values.allSatisfy({ $0 >= 1.0 }) else { return }
        session?.finishTasksAndInvalidate()
        session = nil
    }

    func startDownload(url: URL, id: UUID) {
        let task = currentSession().downloadTask(with: url)
        task.taskDescription = id.uuidString
        activeDownloads[id] = 0
        task.resume()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                 totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0,
              let idString = downloadTask.taskDescription, let id = UUID(uuidString: idString) else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.activeDownloads[id] = progress }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didFinishDownloadingTo location: URL) {
        guard let idString = downloadTask.taskDescription, let id = UUID(uuidString: idString) else { return }
        let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(id.uuidString).mp4")
        try? FileManager.default.moveItem(at: location, to: dest)
        Task { @MainActor in self.activeDownloads[id] = 1.0 }
    }
}
