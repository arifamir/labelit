import Foundation
import LabelItCore

/// Decides which file events matter and when a file has finished arriving (its size stopped changing, no
/// partial-download extension). The same on every platform; each platform's `FolderWatcher` feeds it events.
/// Not thread-safe: the watcher calls it from its one queue or thread.
final class ArrivalTracker {
    /// Extensions of files still being written by browsers and transfer tools.
    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]

    let roots: [URL]
    let maxDepth: Int
    private let handler: @Sendable (URL) -> Void
    private var pending: [String: (size: Int64, stableCount: Int, firstSeen: Date)] = [:]

    init(folders: [URL], maxDepth: Int, handler: @escaping @Sendable (URL) -> Void) {
        self.roots = folders.map { URL(fileURLWithPath: Paths.canonical($0), isDirectory: true) }
        self.maxDepth = maxDepth
        self.handler = handler
    }

    /// A file was created, renamed into place or written to.
    func touched(_ path: String) {
        guard shouldConsider(path), pending[path] == nil else { return }
        pending[path] = (-1, 0, Date())
    }

    func reset() { pending.removeAll() }

    func shouldConsider(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if Self.partialExtensions.contains(url.pathExtension.lowercased()) { return false }
        guard let root = roots.first(where: { path.hasPrefix($0.path + "/") }) else { return false }
        let relative = path.dropFirst(root.path.count + 1).split(separator: "/")
        guard relative.count <= maxDepth + 1 else { return false }
        for component in relative.dropLast() where Self.skipsFolder(String(component)) { return false }
        return !(relative.last?.hasPrefix(".") ?? true)
    }

    /// Never look inside hidden folders, app bundles or libraries (e.g. the Photos library) — or inside a download
    /// that's still arriving: Safari keeps it in a "name.download" folder.
    static func skipsFolder(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return name.hasPrefix(".") || lowered.contains(".photoslibrary") || lowered.hasSuffix(".app")
            || lowered.hasSuffix(".bundle") || lowered.hasSuffix(".lrlibrary")
            || partialExtensions.contains { lowered.hasSuffix("." + $0) }
    }

    /// Called about once a second: reports files whose size held for two checks in a row.
    func check() {
        let fileManager = FileManager.default
        for (path, state) in pending {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value else {
                // Gone (renamed or deleted) — or not created yet; give it a moment.
                if Date().timeIntervalSince(state.firstSeen) > 10 { pending[path] = nil }
                continue
            }
            if Date().timeIntervalSince(state.firstSeen) > 600 { pending[path] = nil; continue }
            if size > 0 && size == state.size {
                if state.stableCount >= 1 {
                    pending[path] = nil
                    handler(URL(fileURLWithPath: path))
                } else {
                    pending[path] = (size, state.stableCount + 1, state.firstSeen)
                }
            } else {
                pending[path] = (size, 0, state.firstSeen)
            }
        }
    }
}
