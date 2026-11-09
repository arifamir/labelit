import Foundation

/// The folders LabelIt watches for phone files: Downloads, Desktop and Pictures until someone changes the list.
/// Each is watched `depth` folders deep, so a folder inside one already on the list is usually covered.
public enum WatchFolders {
    /// How far into a folder LabelIt looks: Downloads/Phone/2026 yes, one level more no.
    public static let depth = 2

    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case notAFolder
        case tooBroad
        case package
        case alreadyWatched
        case coveredBy(String)

        public var description: String {
            switch self {
            case .notAFolder: "isn't a folder"
            case .tooBroad: "is too broad to watch; choose a folder inside it"
            case .package: "is an app or library, not a folder of files"
            case .alreadyWatched: "is already watched"
            case .coveredBy(let name): "is already watched as part of \(name)"
            }
        }
    }

    public static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["Downloads", "Desktop", "Pictures"].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// The list with `candidates` added, and why any weren't. A new folder replaces those inside it that it now covers.
    public static func adding(_ candidates: [URL], to folders: [URL],
                              home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> (folders: [URL], rejected: [(folder: URL, reason: Rejection)]) {
        var list = folders.map(normalized)
        var rejected: [(URL, Rejection)] = []
        for candidate in candidates.map(normalized) {
            if let reason = rejection(for: candidate, in: list, home: normalized(home)) {
                rejected.append((candidate, reason))
                continue
            }
            list.removeAll { covers(candidate, $0) }
            list.append(candidate)
        }
        return (list, rejected)
    }

    static func rejection(for folder: URL, in list: [URL], home: URL) -> Rejection? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            return .notAFolder
        }
        let name = folder.lastPathComponent.lowercased()
        if [".app", ".photoslibrary", ".bundle", ".lrlibrary", ".framework"].contains(where: name.hasSuffix) {
            return .package
        }
        // Whole disks, the home folder, and folders full of apps' own files: too many files that aren't the person's.
        let broad = ["/", "/Users", "/home", "/System", "/Library", "/Applications", "/usr", "/etc", "/var", "/private",
                     home.path, home.appendingPathComponent("Library").path]
        if broad.contains(folder.path) || folder.path.hasPrefix(home.appendingPathComponent("Library").path + "/") {
            return .tooBroad
        }
        if list.contains(where: { $0.path == folder.path }) { return .alreadyWatched }
        if let parent = list.first(where: { covers($0, folder) }) { return .coveredBy(parent.lastPathComponent) }
        return nil
    }

    /// Whether watching `parent` already sees files in `child` (inside it, at most `depth` levels down).
    static func covers(_ parent: URL, _ child: URL) -> Bool {
        guard child.path.hasPrefix(parent.path + "/") else { return false }
        let levels = child.path.dropFirst(parent.path.count + 1).split(separator: "/").count
        return levels <= depth
    }

    static func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: Paths.canonical(url), isDirectory: true)
    }
}
