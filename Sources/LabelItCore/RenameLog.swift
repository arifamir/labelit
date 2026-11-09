import Foundation

/// One file move. A rename can move several files (a Live Photo's image and video).
public struct FileMove: Codable, Sendable, Equatable, Hashable {
    public var from: String
    public var to: String
    /// The renamed file's inode and creation time, so undo can tell it apart from a different file that took its
    /// name later. Both: Linux reuses a deleted file's inode at once; a new file never shares a creation time.
    public var fileID: UInt64?
    public var created: Date?

    public init(from: String, to: String, fileID: UInt64? = nil, created: Date? = nil) {
        self.from = from
        self.to = to
        self.fileID = fileID
        self.created = created
    }

    /// The move, with the identity of the file now at `to`.
    func identified(fileManager: FileManager = .default) -> FileMove {
        let identity = Self.identity(atPath: to, fileManager: fileManager)
        return FileMove(from: from, to: to, fileID: identity.fileID, created: identity.created)
    }

    static func identity(atPath path: String, fileManager: FileManager = .default) -> (fileID: UInt64?, created: Date?) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return (nil, nil) }
        let number = attributes[.systemFileNumber]
        let id = (number as? NSNumber)?.uint64Value ?? (number as? UInt64) ?? (number as? Int).map { UInt64($0) }
        return (id, FileDates.created(atPath: path))
    }

    /// False when the file at `to` is provably not the one LabelIt renamed.
    func isSameFile(fileManager: FileManager = .default) -> Bool {
        let now = Self.identity(atPath: to, fileManager: fileManager)
        if let fileID, let current = now.fileID, current != fileID { return false }
        if let created, let current = now.created, abs(current.timeIntervalSince(created)) > 0.001 { return false }
        return true
    }
}

public struct RenameEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var date: Date
    public var source: Source
    public var kind: FileKind
    public var namer: NamerKind
    public var moves: [FileMove]
    public var context: CaptureContext?
    public var undone: Bool

    public init(id: UUID = UUID(), date: Date = Date(), source: Source, kind: FileKind, namer: NamerKind,
                moves: [FileMove], context: CaptureContext? = nil, undone: Bool = false) {
        self.id = id
        self.date = date
        self.source = source
        self.kind = kind
        self.namer = namer
        self.moves = moves
        self.context = context
        self.undone = undone
    }

    public var primary: FileMove { moves[0] }
    /// A ⌘⇧1 capture has no earlier name to go back to: it came from a temporary file.
    public var canUndo: Bool { !undone && source != .capture }
    public var newName: String { (primary.to as NSString).lastPathComponent }
    public var originalName: String { (primary.from as NSString).lastPathComponent }
}

public enum UndoError: Error, LocalizedError, Equatable {
    case alreadyUndone
    case fileMissing(String)
    case originalTaken(String)
    case notUndoable

    public var errorDescription: String? {
        switch self {
        case .alreadyUndone: return "This rename was already undone."
        case .fileMissing(let name): return "\(name) was moved or deleted since LabelIt renamed it."
        case .originalTaken(let name): return "Another file is already called \(name)."
        case .notUndoable: return "A capture has no earlier name to go back to. Delete it if you don't want it."
        }
    }
}

/// History of every rename, stored as JSON so any rename can be undone later.
public actor RenameLog {
    public static let maxEntries = 2000

    private let fileURL: URL
    private var entries: [RenameEntry]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        if let decoded = try? JSONDecoder.labelIt.decode([RenameEntry].self, from: data) {
            entries = decoded
        } else {
            // Unreadable (damaged, or written by a newer version): keep it aside rather than overwrite it.
            entries = []
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("unreadable-\(stamp)"))
        }
    }

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("LabelIt", isDirectory: true).appendingPathComponent("history.json")
    }

    public func all() -> [RenameEntry] { entries }

    public func recent(_ limit: Int) -> [RenameEntry] { Array(entries.prefix(limit)) }

    public func record(_ entry: RenameEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        save()
    }

    /// Moves every file back to its original name. Checks everything first, and puts back what it moved
    /// if a later move fails, so it never half-undoes.
    public func undo(_ id: UUID, fileManager: FileManager = .default) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[index]
        guard !entry.undone else { throw UndoError.alreadyUndone }
        guard entry.source != .capture else { throw UndoError.notUndoable }
        for move in entry.moves {
            let name = (move.to as NSString).lastPathComponent
            guard fileManager.fileExists(atPath: move.to) else { throw UndoError.fileMissing(name) }
            // Same name, different file: the renamed one was deleted and something else took its name.
            guard move.isSameFile(fileManager: fileManager) else { throw UndoError.fileMissing(name) }
            guard !fileManager.fileExists(atPath: move.from) else {
                throw UndoError.originalTaken((move.from as NSString).lastPathComponent)
            }
        }
        var done: [FileMove] = []
        do {
            for move in entry.moves {
                try fileManager.moveItem(atPath: move.to, toPath: move.from)
                done.append(move)
            }
        } catch {
            for move in done.reversed() { try? fileManager.moveItem(atPath: move.from, toPath: move.to) }
            throw error
        }
        entries[index].undone = true
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.labelIt.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("LabelIt: couldn't save history: \(error)")
        }
    }
}

extension JSONEncoder {
    static var labelIt: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var labelIt: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
