import Foundation
import CryptoKit
import Observation
import AppKit

extension Persistence {
    /// Downloaded models live here. Under the App Sandbox this resolves inside the app's
    /// data container, so it survives app updates and is never inside the .app bundle.
    static var modelsDirectory: URL {
        let dir = directory.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Downloads and manages model files with live progress. Files are moved into the
/// persistent Models container; an optional SHA-256 is verified when present.
@MainActor
@Observable
final class ModelDownloadManager {
    private(set) var states: [String: ModelDownloadState] = [:]

    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var destinations: [String: URL] = [:]
    @ObservationIgnored private var expectedHashes: [String: String] = [:]
    /// Ids cancelled after their download task already finished writing, so the queued
    /// completion handler knows to discard the file instead of installing it.
    @ObservationIgnored private var cancelledIDs: Set<String> = []
    @ObservationIgnored private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: Delegate(manager: self), delegateQueue: nil)
    }()

    func localURL(for model: ModelInfo) -> URL? {
        guard let fileName = model.fileName else { return nil }
        // Shipped inside the app bundle (Contents/Resources/Models): ready to use with no download,
        // and it survives sandbox resets. Checked first so bundled models always resolve.
        if let bundled = bundledURL(fileName) { return bundled }
        // Otherwise a user download in the sandbox container.
        let url = Persistence.modelsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func bundledURL(_ fileName: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("Models/\(fileName)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// True when the model ships inside the app bundle (read-only - can't be deleted or re-downloaded).
    func isBundled(_ model: ModelInfo) -> Bool {
        guard let fileName = model.fileName else { return false }
        return bundledURL(fileName) != nil
    }

    func refreshInstalled(catalog: [ModelInfo]) {
        for model in catalog where !model.isBuiltIn {
            if localURL(for: model) != nil {
                if states[model.id]?.isDownloading != true { states[model.id] = .installed }
            } else if states[model.id] == nil {
                states[model.id] = .notInstalled
            }
        }
    }

    func download(_ model: ModelInfo) {
        guard let url = model.downloadURL, let fileName = model.fileName else { return }
        if states[model.id]?.isDownloading == true { return }
        cancelledIDs.remove(model.id)
        states[model.id] = .downloading(progress: 0)
        destinations[model.id] = Persistence.modelsDirectory.appendingPathComponent(fileName)
        expectedHashes[model.id] = model.sha256
        let task = session.downloadTask(with: url)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancel(_ model: ModelInfo) {
        cancelledIDs.insert(model.id)
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        destinations[model.id] = nil
        expectedHashes[model.id] = nil
        states[model.id] = .notInstalled
    }

    func delete(_ model: ModelInfo) {
        guard !isBundled(model) else { return }   // shipped with the app; nothing to remove
        let url = Persistence.modelsDirectory.appendingPathComponent(model.fileName ?? "")
        try? FileManager.default.removeItem(at: url)
        states[model.id] = .notInstalled
    }

    func totalInstalledBytes(catalog: [ModelInfo]) -> Int64 {
        var total: Int64 = 0
        for model in catalog {
            if let url = localURL(for: model),
               let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Persistence.modelsDirectory])
    }

    // MARK: Delegate callbacks (hopped to main)

    fileprivate func updateProgress(id: String, fraction: Double) {
        states[id] = .downloading(progress: fraction)
    }

    fileprivate func completeDownload(id: String, stagedURL: URL) {
        defer { tasks[id] = nil }
        // The task finished writing before cancel() ran: discard the file, don't install it.
        if cancelledIDs.contains(id) {
            cancelledIDs.remove(id)
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }
        guard let destination = destinations[id] else {
            try? FileManager.default.removeItem(at: stagedURL)
            states[id] = .failed("Missing destination")
            return
        }
        if let expected = expectedHashes[id] ?? nil, let actual = Self.sha256(of: stagedURL),
           actual.caseInsensitiveCompare(expected) != .orderedSame {
            try? FileManager.default.removeItem(at: stagedURL)
            states[id] = .failed("Checksum mismatch")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: stagedURL, to: destination)
            states[id] = .installed
        } catch {
            states[id] = .failed(error.localizedDescription)
        }
    }

    fileprivate func failDownload(id: String, message: String) {
        tasks[id] = nil
        states[id] = .failed(message)
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// URLSession delegate kept separate so the manager can stay @MainActor.
    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        weak var manager: ModelDownloadManager?
        init(manager: ModelDownloadManager) { self.manager = manager }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let id = downloadTask.taskDescription ?? ""
            let fraction = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
            Task { @MainActor [weak manager] in manager?.updateProgress(id: id, fraction: fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let id = downloadTask.taskDescription ?? ""
            // The temp file is only valid during this call; stage it synchronously.
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: staged)
            } catch {
                Task { @MainActor [weak manager] in manager?.failDownload(id: id, message: error.localizedDescription) }
                return
            }
            Task { @MainActor [weak manager] in manager?.completeDownload(id: id, stagedURL: staged) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            let id = task.taskDescription ?? ""
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }
            Task { @MainActor [weak manager] in manager?.failDownload(id: id, message: error.localizedDescription) }
        }
    }
}
