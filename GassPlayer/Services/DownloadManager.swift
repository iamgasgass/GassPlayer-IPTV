import Foundation
import Combine

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var activeDownloads: [UUID: Double] = [:]
    @Published var wifiOnly: Bool = true

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.iamgasgass.gassPlayer.downloads")
        config.allowsCellularAccess = !wifiOnly
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Prima era `return true` fisso: ora usa NetworkMonitor reale
    /// (NWPathMonitor), quindi "solo Wi-Fi" funziona davvero.
    func startDownload(url: URL, id: UUID) {
        if wifiOnly && !NetworkMonitor.shared.isOnWiFi {
            DebugLogger.logAsync(.warning, "Download bloccato: modalità solo Wi-Fi attiva e rete corrente non è Wi-Fi")
            return
        }
        let task = session.downloadTask(with: url)
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
