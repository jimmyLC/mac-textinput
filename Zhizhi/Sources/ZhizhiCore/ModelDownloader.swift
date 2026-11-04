import CryptoKit
import Foundation

/// The local model: a fixed revision and fixed hashes, so what runs is exactly what was evaluated.
public struct ModelManifest {
    public struct File: Equatable {
        public var name: String
        public var size: Int64
        public var sha256: String
        public init(name: String, size: Int64, sha256: String) { self.name = name; self.size = size; self.sha256 = sha256 }
    }
    public var name: String
    public var baseURL: URL
    public var files: [File]
    public init(name: String, baseURL: URL, files: [File]) { self.name = name; self.baseURL = baseURL; self.files = files }

    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    public static let qwen = ModelManifest(
        name: "Qwen2.5-1.5B-4bit",
        baseURL: URL(string: "https://huggingface.co/mlx-community/Qwen2.5-1.5B-4bit/resolve/df5d0cfe2b3cab6481bc34dd4474be883bfec031/")!,
        files: [
            .init(name: "config.json", size: 808, sha256: "218a69f4e52df93a91e1e062a81f423cdd3ab43b48c5c6fd23a43e90712f791a"),
            .init(name: "tokenizer.json", size: 7_031_673, sha256: "a8506e7111b80c6d8635951a02eab0f4e1a8e4e5772da83846579e97b16f61bf"),
            .init(name: "tokenizer_config.json", size: 7_228, sha256: "dced901d401aa828f313a2baec70d0ce164653285812237b5285c7efd5b9e760"),
            .init(name: "vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            .init(name: "merges.txt", size: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            .init(name: "added_tokens.json", size: 605, sha256: "58b54bbe36fc752f79a24a271ef66a0a0830054b4dfad94bde757d851968060b"),
            .init(name: "special_tokens_map.json", size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
            .init(name: "model.safetensors.index.json", size: 51_569, sha256: "6b98634d5044f0e2ad45228a374f8445904e571f1082392d08a6ce54f5d517ca"),
            .init(name: "model.safetensors", size: 868_628_559, sha256: "9e5510a01800d8f1cf3b70e4c1e70e008bffd082b8880b2c7128075225c9e958"),
        ])
}

/// Downloads into a hidden folder, checks every hash, and only then moves it into place, so a
/// half-finished download never looks like a model. Finished files survive a cancel or a failure.
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    public enum Failure: Error, Equatable {
        case badResponse(String)
        case hashMismatch(String)
        case cancelled
    }

    public let manifest: ModelManifest
    public let folder: URL
    private var partial: URL { folder.deletingLastPathComponent().appendingPathComponent(".\(folder.lastPathComponent).partial") }

    private var session: URLSession?
    private var queue: [ModelManifest.File] = []
    private var current: ModelManifest.File?
    private var finishedBytes: Int64 = 0
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Result<Void, Error>) -> Void)?
    private var stored: Error?

    public init(manifest: ModelManifest, folder: URL) {
        self.manifest = manifest
        self.folder = folder
    }

    /// True for a real folder or a development link, as long as the weights are there.
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.safetensors").path)
    }

    /// Removes the model. A development link is removed without touching what it points to.
    public func remove() throws {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil || fm.fileExists(atPath: folder.path) {
            try fm.removeItem(at: folder)
        }
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
    }

    /// Progress runs from 0 to 1. Both callbacks arrive on the main queue.
    public func start(progress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        onProgress = progress
        onDone = completion
        do {
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        } catch {
            finish(.failure(error))
            return
        }
        finishedBytes = 0
        queue = manifest.files.filter { file in
            if isComplete(file) { finishedBytes += file.size; return false }
            try? FileManager.default.removeItem(at: partial.appendingPathComponent(file.name))
            return true
        }
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        next()
    }

    public func cancel() {
        stored = Failure.cancelled
        session?.invalidateAndCancel()
    }

    private func isComplete(_ file: ModelManifest.File) -> Bool {
        let url = partial.appendingPathComponent(file.name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == file.size else { return false }
        return (try? Self.sha256(of: url)) == file.sha256
    }

    private func next() {
        guard let file = queue.first else {
            do {
                let fm = FileManager.default
                if (try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil || fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
                try fm.moveItem(at: partial, to: folder)
                finish(.success(()))
            } catch {
                finish(.failure(error))
            }
            return
        }
        queue.removeFirst()
        current = file
        session?.downloadTask(with: manifest.baseURL.appendingPathComponent(file.name)).resume()
    }

    private func finish(_ result: Result<Void, Error>) {
        session?.finishTasksAndInvalidate()
        session = nil
        let done = onDone
        onDone = nil
        DispatchQueue.main.async { done?(result) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = max(manifest.totalSize, 1)
        let fraction = min(1, Double(finishedBytes + totalBytesWritten) / Double(total))
        let report = onProgress
        DispatchQueue.main.async { report?(fraction) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let file = current else { return }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            stored = Failure.badResponse("\(file.name): HTTP \(http.statusCode)")
            return
        }
        do {
            guard try Self.sha256(of: location) == file.sha256 else { throw Failure.hashMismatch(file.name) }
            let target = partial.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            finishedBytes += file.size
        } catch {
            stored = error
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure = stored ?? error {
            stored = nil
            finish(.failure(failure))
        } else {
            next()
        }
    }

    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let stored {
            self.stored = nil
            finish(.failure(stored))
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
