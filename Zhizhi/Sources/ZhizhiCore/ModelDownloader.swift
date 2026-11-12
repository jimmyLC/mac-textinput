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
    /// Output file → the downloaded pieces to join, in order (a host that caps single uploads gets pieces).
    public var assemble: [String: [String]]
    public init(name: String, baseURL: URL, files: [File], assemble: [String: [String]] = [:]) {
        self.name = name; self.baseURL = baseURL; self.files = files; self.assemble = assemble
    }

    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Qwen2.5-1.5B-4bit with a spoken-Taiwan-Chinese LoRA fused in (training/README.md), served from our own site.
    public static let qwen = ModelManifest(
        name: "Zhizhi-Qwen1.5B-spoken1",
        baseURL: URL(string: "https://zhizhi.jimmy-tools.com/downloads/models-spoken1/")!,
        files: [
            .init(name: "config.json", size: 888, sha256: "2b4bedf383e1e9e8bc535d0d6a89b18a862c0850b4795edec11472c29ea6e995"),
            .init(name: "tokenizer.json", size: 11_421_892, sha256: "3fd169731d2cbde95e10bf356d66d5997fd885dd8dbb6fb4684da3f23b2585d8"),
            .init(name: "tokenizer_config.json", size: 728, sha256: "5aa5069e1b0c0d623ce38e0df387e506b843e5c4d612a36d2e79e46a400e6450"),
            .init(name: "vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            .init(name: "merges.txt", size: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            .init(name: "added_tokens.json", size: 605, sha256: "58b54bbe36fc752f79a24a271ef66a0a0830054b4dfad94bde757d851968060b"),
            .init(name: "special_tokens_map.json", size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
            .init(name: "model.safetensors.index.json", size: 51_609, sha256: "19e664257b50911ac12ff231c42e952c210d48d1861f7fa304eb640dd10dccb8"),
            .init(name: "model.safetensors.part1", size: 289_542_849, sha256: "da01a4ac307e09ef7f7acf93311d2b424a1f9687fbddd63cdb131f5c847fdb98"),
            .init(name: "model.safetensors.part2", size: 289_542_849, sha256: "a2d6730d0d1d79d2e9577f4b43f7b5096a4fc39f848f6fd13846035274b27b19"),
            .init(name: "model.safetensors.part3", size: 289_542_849, sha256: "8fcdfe1c4c2baa6f95b1ca454cb8fe0e54dcdad60b260223c5ea8a22436f3095"),
        ],
        assemble: ["model.safetensors": ["model.safetensors.part1", "model.safetensors.part2", "model.safetensors.part3"]])
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

    /// Joins pieces into their output file, then drops the pieces.
    private func assembleParts() throws {
        let fm = FileManager.default
        for (output, parts) in manifest.assemble {
            let target = partial.appendingPathComponent(output)
            fm.createFile(atPath: target.path, contents: nil)
            let out = try FileHandle(forWritingTo: target)
            defer { try? out.close() }
            for part in parts {
                let url = partial.appendingPathComponent(part)
                let input = try FileHandle(forReadingFrom: url)
                while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
                try input.close()
                try fm.removeItem(at: url)
            }
        }
    }

    private func next() {
        guard let file = queue.first else {
            do {
                let fm = FileManager.default
                try assembleParts()
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
