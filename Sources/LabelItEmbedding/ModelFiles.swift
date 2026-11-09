// The pinned EmbeddingGemma 2 files (repository, revision, sizes, SHA-256) are the ones DigUp uses
// (https://github.com/ARahim3/DigUp, MIT), so both apps can share one download.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession on Linux
#endif

/// The EmbeddingGemma 2 files for llama.cpp: the same pinned files DigUp uses, so one download serves both apps.
public enum ModelFiles {
    public static let repository = "ggml-org/embeddinggemma-2-GGUF"
    public static let revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"

    public struct File: Sendable {
        public let name: String
        public let bytes: Int64
        public let sha256: String

        public var url: URL {
            URL(string: "https://huggingface.co/\(ModelFiles.repository)/resolve/\(ModelFiles.revision)/\(name)")!
        }
    }

    /// The text model (310 MB).
    public static let text = File(name: "embeddinggemma-2-Q8_0.gguf", bytes: 309_855_456,
                                  sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135")
    /// The image encoder (555 MB).
    public static let media = File(name: "mmproj-embeddinggemma-2-Q8_0.gguf", bytes: 554_821_024,
                                   sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")
    public static let all = [text, media]
    public static var totalBytes: Int64 { all.reduce(0) { $0 + $1.bytes } }

    public struct Located: Sendable, Equatable {
        public let text: URL
        public let media: URL
        public var folder: URL { text.deletingLastPathComponent() }
        public var isDigUps: Bool { folder.path.contains("/DigUp/") }
    }

    /// Where LabelIt downloads the files. LABELIT_MODEL_DIR sets another folder (for tests, or a shared disk).
    public static var labelItFolder: URL {
        if let folder = ProcessInfo.processInfo.environment["LABELIT_MODEL_DIR"], !folder.isEmpty {
            return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LabelIt/Models", isDirectory: true)
    }

    /// Where to look, first match wins: LabelIt's own download, then DigUp's, then the Hugging Face cache.
    public static var folders: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let hubCache = ProcessInfo.processInfo.environment["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        return [
            labelItFolder,
            support.appendingPathComponent("DigUp/Models", isDirectory: true),
            hubCache.appendingPathComponent("models--ggml-org--embeddinggemma-2-GGUF/snapshots/\(revision)"),
        ]
    }

    /// Both files, checked by size (hashing 865 MB on every launch would be slow; downloads are hashed once).
    public static func locate() -> Located? {
        for folder in folders {
            let textURL = folder.appendingPathComponent(text.name)
            let mediaURL = folder.appendingPathComponent(media.name)
            if size(of: textURL) == text.bytes && size(of: mediaURL) == media.bytes {
                return Located(text: textURL, media: mediaURL)
            }
        }
        return nil
    }

    static func size(of url: URL) -> Int64? {
        // Follows symlinks: the Hugging Face cache links snapshots to blobs.
        guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }
}

/// Partly downloaded model files, kept beside the model as "<file>.resume" (URLSession's resume data), so a download
/// that's cut short carries on from where it stopped.
public struct PartialDownloads: Sendable {
    public let folder: URL

    public init(folder: URL = ModelFiles.labelItFolder) {
        self.folder = folder
    }

    func url(for file: ModelFiles.File) -> URL { folder.appendingPathComponent(file.name + ".resume") }

    public func load(_ file: ModelFiles.File) -> Data? {
        #if canImport(Darwin)
        try? Data(contentsOf: url(for: file))
        #else
        nil   // swift-corelibs-foundation can't resume downloads
        #endif
    }

    public func save(_ data: Data?, for file: ModelFiles.File) {
        guard let data, !data.isEmpty else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url(for: file), options: .atomic)
    }

    public func discard(_ file: ModelFiles.File) {
        try? FileManager.default.removeItem(at: url(for: file))
    }
}

/// Downloads the model files into LabelIt's folder, checking each file's SHA-256 before it's used.
///
/// A download that's cut short keeps what it got: a dropped network is retried a few times, and when the Mac sleeps,
/// LabelIt quits or the download is cancelled, the next start carries on from the same place.
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case verifying
        case finished
        case failed(String)
    }

    /// Waits before each retry after a network error; when they're used up, the download fails (and can be resumed).
    static let retryDelays: [Double] = [5, 20, 60]

    private let onChange: @Sendable (State) -> Void
    private let partials: PartialDownloads
    private var session: URLSession?
    private var queue: [ModelFiles.File] = []
    private var current: ModelFiles.File?
    private var task: URLSessionDownloadTask?
    /// Whether `task` carries on from a partial download.
    private var resuming = false
    /// Failed tries at the current file.
    private var failures = 0
    private var completedBytes: Int64 = 0
    private let lock = NSLock()
    private var cancelled = false

    public init(partials: PartialDownloads = PartialDownloads(), onChange: @escaping @Sendable (State) -> Void) {
        self.partials = partials
        self.onChange = onChange
    }

    public func start() {
        lock.withLock {
            try? FileManager.default.createDirectory(at: ModelFiles.labelItFolder, withIntermediateDirectories: true)
            queue = ModelFiles.all.filter {
                ModelFiles.size(of: ModelFiles.labelItFolder.appendingPathComponent($0.name)) != $0.bytes
            }
            completedBytes = ModelFiles.totalBytes - queue.reduce(0) { $0 + $1.bytes }
            session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        }
        next()
    }

    /// Stops the download, keeping what it got for the next start.
    public func stop() async {
        let (task, file) = lock.withLock {
            cancelled = true
            queue = []
            return (self.task, current)
        }
        if let task, let file {
            let data = await withCheckedContinuation { continuation in
                task.cancel(byProducingResumeData: { continuation.resume(returning: $0) })
            }
            partials.save(data, for: file)
        }
        lock.withLock {
            session?.invalidateAndCancel()
            session = nil
            self.task = nil
        }
        onChange(.idle)
    }

    /// ``stop()``, without waiting for it.
    public func cancel() {
        Task { await stop() }
    }

    private func next() {
        enum Step { case cancelled, finished, download(ModelFiles.File) }
        let step: Step = lock.withLock {
            guard !cancelled else { return .cancelled }
            current = queue.isEmpty ? nil : queue.removeFirst()
            failures = 0
            guard let current else {
                session?.finishTasksAndInvalidate()   // a session keeps its delegate alive until invalidated
                session = nil
                return .finished
            }
            return .download(current)
        }
        switch step {
        case .cancelled: return
        case .finished: onChange(.finished)
        case .download(let file): begin(file)
        }
    }

    /// Starts (or carries on with) one file.
    private func begin(_ file: ModelFiles.File, fresh: Bool = false) {
        if fresh { partials.discard(file) }
        let partial = partials.load(file)
        lock.withLock {
            guard let session, !cancelled else { return }
            let task = partial.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: file.url)
            self.task = task
            resuming = partial != nil
            task.resume()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let (done, file) = lock.withLock { (completedBytes, current) }
        // A resumed download counts from where it carried on: what it expects is the part that's left.
        var before: Int64 = 0
        if let file, totalBytesExpectedToWrite > 0, totalBytesExpectedToWrite < file.bytes {
            before = file.bytes - totalBytesExpectedToWrite
        }
        onChange(.downloading(received: done + before + totalBytesWritten, total: ModelFiles.totalBytes))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let (file, wasResuming) = lock.withLock { (current, resuming) }
        guard let file else { return }
        // A server error arrives as a finished download of the error page.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            if wasResuming {
                begin(file, fresh: true)   // the partial download's link expired: start this file over
            } else {
                fail("Hugging Face answered \(status)")
            }
            return
        }
        onChange(.verifying)
        do {
            let digest = try Self.sha256(of: location)
            // Hashing 500 MB takes a few seconds; the download may have been cancelled meanwhile.
            guard !lock.withLock({ cancelled }) else { return }
            partials.discard(file)
            guard digest == file.sha256 else { throw EmbeddingError("\(file.name) didn't match its checksum") }
            let destination = ModelFiles.labelItFolder.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { completedBytes += file.bytes }
            next()
        } catch {
            fail("\(error)")
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        #if canImport(Darwin)
        let partial = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        #else
        let partial: Data? = nil   // swift-corelibs-foundation can't resume downloads
        #endif
        let (file, isCurrent, wasResuming, failures): (ModelFiles.File?, Bool, Bool, Int) = lock.withLock {
            let isCurrent = task === self.task && !cancelled
            if isCurrent { self.failures += 1 }
            return (current, isCurrent, resuming, self.failures)
        }
        guard let file else { return }
        partials.save(partial, for: file)
        // Cancelled on purpose: stop() keeps the partial download.
        guard isCurrent, nsError.code != NSURLErrorCancelled else { return }
        // A partial download that didn't carry on and left nothing new to resume from is no use any more.
        let fresh = wasResuming && partial == nil
        guard failures <= Self.retryDelays.count else {
            fail(error.localizedDescription)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.retryDelays[failures - 1]) { [weak self] in
            guard let self, !self.lock.withLock({ self.cancelled }) else { return }
            self.begin(file, fresh: fresh)
        }
    }

    private func fail(_ message: String) {
        lock.withLock {
            session?.finishTasksAndInvalidate()
            session = nil
        }
        onChange(.failed(message))
    }

    static func sha256(of url: URL) throws -> String { try Hashing.sha256Hex(of: url) }
}
