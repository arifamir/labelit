#if os(Linux)
import Foundation
import Glibc

/// Watches folders with inotify and reports files once they've finished arriving (`ArrivalTracker`).
/// inotify watches one folder at a time, so each folder down to `maxDepth` gets a watch, and new folders are added
/// as they appear.
public final class FolderWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (URL) -> Void

    private let queue = DispatchQueue(label: "com.kodberry.labelit.watcher")
    private let tracker: ArrivalTracker
    private var descriptor: Int32 = -1
    private var folders: [Int32: String] = [:]
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?

    private static let events = UInt32(IN_CREATE) | UInt32(IN_MOVED_TO) | UInt32(IN_CLOSE_WRITE) | UInt32(IN_MODIFY)

    public init(folders: [URL], maxDepth: Int = 2, handler: @escaping Handler) {
        tracker = ArrivalTracker(folders: folders, maxDepth: maxDepth, handler: handler)
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit { stop() }

    public func start() {
        queue.sync {
            guard descriptor < 0, !tracker.roots.isEmpty else { return }
            descriptor = inotify_init1(Int32(IN_NONBLOCK) | Int32(IN_CLOEXEC))
            guard descriptor >= 0 else { return }
            for root in tracker.roots { watch(root.path, depth: 0) }

            let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            reader.setEventHandler { [weak self] in self?.drain() }
            reader.resume()
            self.reader = reader

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tracker.check() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        let work = {
            self.reader?.cancel()
            self.reader = nil
            self.timer?.cancel()
            self.timer = nil
            if self.descriptor >= 0 { close(self.descriptor) }
            self.descriptor = -1
            self.folders.removeAll()
            self.tracker.reset()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    public func shouldConsider(_ path: String) -> Bool { tracker.shouldConsider(path) }

    private static let queueKey = DispatchSpecificKey<Void>()

    /// Watches `path` and, within the depth limit, the folders inside it.
    private func watch(_ path: String, depth: Int) {
        let id = inotify_add_watch(descriptor, path, Self.events)
        guard id >= 0 else { return }
        folders[id] = path
        guard depth < tracker.maxDepth,
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for name in names where !ArrivalTracker.skipsFolder(name) {
            var isFolder: ObjCBool = false
            let child = path + "/" + name
            if FileManager.default.fileExists(atPath: child, isDirectory: &isFolder), isFolder.boolValue {
                watch(child, depth: depth + 1)
            }
        }
    }

    private func depth(of path: String) -> Int {
        guard let root = tracker.roots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else { return .max }
        return path.dropFirst(root.path.count).split(separator: "/").count
    }

    /// Reads every waiting event: `struct inotify_event { int wd; uint32_t mask, cookie, len; char name[len]; }`.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            var offset = 0
            while offset + 16 <= count {
                let (id, mask, length) = buffer.withUnsafeBytes { bytes in
                    (bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self),
                     bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self),
                     Int(bytes.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self)))
                }
                let nameBytes = buffer[(offset + 16)..<min(offset + 16 + length, count)].prefix { $0 != 0 }
                offset += 16 + length
                guard let folder = folders[id], !nameBytes.isEmpty else { continue }
                let path = folder + "/" + String(decoding: nameBytes, as: UTF8.self)
                if mask & UInt32(IN_ISDIR) != 0 {
                    // A new folder: watch it too, if it's not too deep or skipped.
                    let name = String(decoding: nameBytes, as: UTF8.self)
                    if mask & (UInt32(IN_CREATE) | UInt32(IN_MOVED_TO)) != 0, !ArrivalTracker.skipsFolder(name),
                       depth(of: path) <= tracker.maxDepth {
                        watch(path, depth: depth(of: path))
                    }
                } else {
                    tracker.touched(path)
                }
            }
        }
    }
}
#endif
