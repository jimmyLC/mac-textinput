import Foundation

/// Talks to the `zhizhi-ai` child process over pipes. Nothing leaves the machine and nothing is
/// written to disk. The child exits by itself when idle and is started again on the next request.
public final class HelperClient {
    public typealias Completion = ([Float]?) -> Void

    private let executable: URL
    private let model: URL
    private let queue = DispatchQueue(label: "zhizhi.helper")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var ready = false
    private var nextID = 0
    private var waiting: [Int: Completion] = [:]
    private var unsent: [Data] = []

    /// A model trained on this Mac's own typing. It never leaves the Mac, and wins over `model` when present.
    public static let personalFolderName = "Zhizhi-personal"
    private let personal: URL?
    private var runningModel: URL?

    public init(executable: URL, model: URL, personal: URL? = nil) {
        self.executable = executable
        self.model = model
        self.personal = personal
    }

    private static func hasWeights(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.safetensors").path)
    }
    /// The folder used for the next request: the personal model if it is complete, else the shared one.
    public var activeModel: URL {
        if let personal, Self.hasWeights(personal) { return personal }
        return model
    }
    public var isUsingPersonalModel: Bool { activeModel != model }

    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path) && Self.hasWeights(activeModel)
    }

    /// Scores texts in the background. The completion runs on a private queue, with nil on failure.
    public func score(_ texts: [String], completion: @escaping Completion) {
        queue.async { [self] in
            guard isAvailable, startIfNeeded() else { completion(nil); return }
            nextID += 1
            guard let body = try? JSONSerialization.data(withJSONObject: ["id": nextID, "texts": texts]) else {
                completion(nil)
                return
            }
            waiting[nextID] = completion
            let line = body + Data([0x0A])
            if ready { write(line) } else { unsent.append(line) }
        }
    }

    /// Frees the model's memory now.
    public func stop() {
        queue.async { [self] in
            process?.terminate()
            finish()
        }
    }

    private func startIfNeeded() -> Bool {
        let wanted = activeModel
        if process?.isRunning == true {
            if runningModel == wanted { return true }
            process?.terminate()   // the personal model appeared or went away: start again on the right one
        }
        finish()
        runningModel = wanted
        let child = Process()
        child.executableURL = executable
        child.arguments = [wanted.path]
        let stdin = Pipe(), stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.received(data) }
        }
        child.terminationHandler = { [weak self] ended in
            self?.queue.async { if self?.process === ended { self?.finish() } }
        }
        do { try child.run() } catch { return false }
        process = child
        input = stdin.fileHandleForWriting
        return true
    }

    private func write(_ line: Data) {
        do { try input?.write(contentsOf: line) } catch { finish() }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if object["ready"] != nil {
                ready = true
                unsent.forEach(write)
                unsent.removeAll()
            } else if let id = object["id"] as? Int, let done = waiting.removeValue(forKey: id) {
                done((object["logprobs"] as? [Double])?.map(Float.init))
            }
        }
    }

    /// The child is gone: nothing that was waiting will ever be answered.
    private func finish() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        input = nil
        ready = false
        buffer.removeAll()
        unsent.removeAll()
        let abandoned = waiting
        waiting.removeAll()
        abandoned.values.forEach { $0(nil) }
    }
}
