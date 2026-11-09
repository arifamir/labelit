import Foundation

public enum Slug {
    /// Turns free text into `lowercase-words-joined-by-hyphens`.
    /// Keeps letters from any script (Bengali, Arabic…), drops accents, punctuation and emoji.
    public static func make(_ text: String, maxWords: Int = 6, maxLength: Int = 60) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }

        // Each word once ("content-privacy-restrictions-content-privacy"), and no random IDs
        // like "xubndtodokkuyqaregv4uw" — they make a name longer, not easier to find.
        var unique: [String] = []
        for word in words where !unique.contains(word) && !looksLikeID(word) { unique.append(word) }

        var result = ""
        for word in unique.prefix(maxWords) {
            let next = result.isEmpty ? word : result + "-" + word
            if next.count > maxLength { break }
            result = next
        }
        return result
    }

    static func looksLikeID(_ word: String) -> Bool {
        if word.count >= 20 { return true }
        guard word.count >= 10 else { return false }
        let hasDigit = word.contains { $0.isNumber }
        let hasLetter = word.contains { $0.isLetter }
        return hasDigit && hasLetter
    }
}

/// Builds final file names and resolves collisions.
public struct FilenameBuilder: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Base name without extension.
    ///
    /// - Screenshots: `slug_2026-11-02_184107` (time keeps a burst of captures apart)
    /// - Phone media: `slug_lisbon_2026-11-02`
    /// - Files picked in Finder: like a screenshot when they show a screen, like phone media otherwise
    public func baseName(slug: String, kind: FileKind, source: Source, date: Date, place: String?) -> String {
        let safeSlug = slug.isEmpty ? Self.fallbackSlug(for: kind) : slug
        var parts = [safeSlug]
        let isScreen = switch source {
        case .capture, .screenshot: true
        case .phone: false
        case .finder: [.screenshot, .ui, .error].contains(kind)
        }
        if isScreen {
            parts.append(format(date, "yyyy-MM-dd"))
            parts.append(format(date, "HHmmss"))
        } else {
            if let place, !place.isEmpty {
                let placeSlug = Slug.make(place, maxWords: 3, maxLength: 30)
                if !placeSlug.isEmpty && !safeSlug.contains(placeSlug) { parts.append(placeSlug) }
            }
            parts.append(format(date, "yyyy-MM-dd"))
        }
        return parts.joined(separator: "_")
    }

    /// A URL in `directory` that doesn't exist yet: `name.ext`, then `name-2.ext`, `name-3.ext`…
    public func availableURL(in directory: URL, base: String, ext: String, reserved: Set<String> = [],
                             fileManager: FileManager = .default) -> URL {
        let free = availableBase(in: directory, base: base, exts: [ext], reserved: reserved, fileManager: fileManager)
        return Self.url(in: directory, base: free, ext: ext)
    }

    /// A base name that's free with every one of `exts`, so a Live Photo's image and video can share it.
    public func availableBase(in directory: URL, base: String, exts: [String], reserved: Set<String> = [],
                              fileManager: FileManager = .default) -> String {
        var n = 1
        while true {
            let name = n == 1 ? base : "\(base)-\(n)"
            let taken = exts.contains { ext in
                let path = Self.url(in: directory, base: name, ext: ext).path
                return fileManager.fileExists(atPath: path) || reserved.contains(path)
            }
            if !taken { return name }
            n += 1
        }
    }

    public static func url(in directory: URL, base: String, ext: String) -> URL {
        let cleanExt = ext.lowercased()
        return directory.appendingPathComponent(cleanExt.isEmpty ? base : "\(base).\(cleanExt)")
    }

    public static func fallbackSlug(for kind: FileKind) -> String {
        switch kind {
        case .error: return "error"
        case .ui, .screenshot: return "screenshot"
        case .receipt: return "receipt"
        case .document: return "document"
        case .photo: return "photo"
        case .video: return "video"
        case .other: return "file"
        }
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
