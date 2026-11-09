#if os(macOS)
import CoreServices
import Foundation

/// Watches folders with FSEvents and reports files once they've finished arriving (`ArrivalTracker`).
public final class FolderWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (URL) -> Void

    private let queue = DispatchQueue(label: "com.kodberry.labelit.watcher")
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private let tracker: ArrivalTracker

    public init(folders: [URL], maxDepth: Int = 2, handler: @escaping Handler) {
        tracker = ArrivalTracker(folders: folders, maxDepth: maxDepth, handler: handler)
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit { stop() }

    public func start() {
        queue.sync {
            guard stream == nil, !tracker.roots.isEmpty else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
                watcher.received(zip(list, flagList).map { ($0, $1) })
            }
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                               | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, callback, &context, tracker.roots.map(\.path) as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
            else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tracker.check() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        let work = {
            if let stream = self.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            self.stream = nil
            self.timer?.cancel()
            self.timer = nil
            self.tracker.reset()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    public func shouldConsider(_ path: String) -> Bool { tracker.shouldConsider(path) }

    private static let queueKey = DispatchSpecificKey<Void>()

    private func received(_ events: [(String, FSEventStreamEventFlags)]) {
        for (path, flags) in events {
            let isFile = flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
            let interesting = flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
                                             | kFSEventStreamEventFlagItemModified
                                             | kFSEventStreamEventFlagItemInodeMetaMod) != 0
            if isFile && interesting { tracker.touched(path) }
        }
    }
}
#endif
