/// Release versions ("0.1.3", or a tag like "v0.1.3"), compared number by number.
public enum AppVersion {
    /// The numbers of a version: "v0.10.2" → [0, 10, 2]. Nil when it isn't one.
    public static func parse(_ text: String) -> [Int]? {
        let trimmed = text.hasPrefix("v") || text.hasPrefix("V") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// Whether `candidate` is a later version than `current`: 0.1.10 after 0.1.9, 0.2 after 0.1.9. A version that
    /// can't be read is never newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = parse(candidate), let old = parse(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
