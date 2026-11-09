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

    /// Where LabelIt downloads the files.
    public static var labelItFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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

/// Downloads the model files into LabelIt's folder, checking each file's SHA-256 before it's used.
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case verifying
        case finished
        case failed(String)
    }

    private let onChange: @Sendable (State) -> Void
    private var session: URLSession?
    private var queue: [ModelFiles.File] = []
    private var current: ModelFiles.File?
    private var completedBytes: Int64 = 0
    private let lock = NSLock()
    private var cancelled = false

    public init(onChange: @escaping @Sendable (State) -> Void) {
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

    public func cancel() {
        lock.withLock {
            cancelled = true
            session?.invalidateAndCancel()
            session = nil
            queue = []
        }
        onChange(.idle)
    }

    private func next() {
        enum Step { case cancelled, finished, download(ModelFiles.File) }
        let step: Step = lock.withLock {
            guard !cancelled else { return .cancelled }
            current = queue.isEmpty ? nil : queue.removeFirst()
            guard let current else {
                session?.finishTasksAndInvalidate()   // a session keeps its delegate alive until invalidated
                session = nil
                return .finished
            }
            return .download(current)
        }
        let file: ModelFiles.File
        switch step {
        case .cancelled: return
        case .finished: onChange(.finished); return
        case .download(let next): file = next
        }
        lock.withLock { _ = session?.downloadTask(with: file.url).resume() }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let done = lock.withLock { completedBytes } + totalBytesWritten
        onChange(.downloading(received: done, total: ModelFiles.totalBytes))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let file = lock.withLock({ current }) else { return }
        onChange(.verifying)
        do {
            let digest = try Self.sha256(of: location)
            // Hashing 500 MB takes a few seconds; the download may have been cancelled meanwhile.
            guard !lock.withLock({ cancelled }) else { return }
            guard digest == file.sha256 else { throw EmbeddingError("\(file.name) didn't match its checksum") }
            let destination = ModelFiles.labelItFolder.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { completedBytes += file.bytes }
            next()
        } catch {
            onChange(.failed("\(error)"))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        onChange(.failed(error.localizedDescription))
    }

    static func sha256(of url: URL) throws -> String { try Hashing.sha256Hex(of: url) }
}
