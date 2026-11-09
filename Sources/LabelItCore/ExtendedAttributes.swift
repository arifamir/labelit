import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import CLinux
import Glibc
#endif

/// Small wrapper around the extended-attribute syscalls (macOS and Linux; they differ in arguments and naming).
/// Linux keeps user attributes in the `user.` namespace, so names get that prefix there.
/// Windows keeps the equivalent in NTFS alternate data streams; that comes with the Windows port.
public enum ExtendedAttributes {
    static func systemName(_ name: String) -> String {
        #if os(Linux)
        return name.hasPrefix("user.") ? name : "user." + name
        #else
        return name
        #endif
    }

    public static func data(_ name: String, at url: URL) -> Data? {
        #if canImport(Darwin) || os(Linux)
        let name = systemName(name)
        return url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = get(path, name, nil, 0)
            guard size >= 0 else { return nil }
            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { get(path, name, $0.baseAddress, size) }
            return read >= 0 ? buffer.prefix(read) : nil
        }
        #else
        return nil
        #endif
    }

    @discardableResult
    public static func set(_ name: String, data: Data, at url: URL) -> Bool {
        #if canImport(Darwin)
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) } == 0
        }
        #elseif os(Linux)
        let name = systemName(name)
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0) } == 0
        }
        #else
        return false
        #endif
    }

    @discardableResult
    public static func remove(_ name: String, at url: URL) -> Bool {
        #if canImport(Darwin)
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return removexattr(path, name, 0) == 0
        }
        #elseif os(Linux)
        let name = systemName(name)
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return removexattr(path, name) == 0
        }
        #else
        return false
        #endif
    }

    public static func has(_ name: String, at url: URL) -> Bool {
        #if canImport(Darwin) || os(Linux)
        let name = systemName(name)
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return get(path, name, nil, 0) >= 0
        }
        #else
        return false
        #endif
    }

    #if canImport(Darwin)
    private static func get(_ path: UnsafePointer<CChar>, _ name: String, _ value: UnsafeMutableRawPointer?, _ size: Int) -> Int {
        getxattr(path, name, value, size, 0, 0)
    }
    #elseif os(Linux)
    private static func get(_ path: UnsafePointer<CChar>, _ name: String, _ value: UnsafeMutableRawPointer?, _ size: Int) -> Int {
        getxattr(path, name, value, size)
    }
    #endif
}

/// The attributes LabelIt reads and writes.
public enum FileMarkers {
    /// Set on every file LabelIt has handled, so it is never renamed twice.
    /// Extended attributes move with the file, so a later rename by the user keeps it.
    public static let processed = "com.kodberry.labelit.processed"
    /// JSON with what LabelIt learned about the file (kind, app, window, url).
    public static let info = "com.kodberry.labelit.info"
    static let quarantine = "com.apple.quarantine"
    static let whereFroms = "com.apple.metadata:kMDItemWhereFroms"
    /// The freedesktop equivalents (Linux file managers: Dolphin shows tags; both record a download's source).
    static let xdgTags = "user.xdg.tags"
    static let xdgOrigin = "user.xdg.origin.url"
    static let isScreenCapture = "com.apple.metadata:kMDItemIsScreenCapture"

    public static func isProcessed(_ url: URL) -> Bool { ExtendedAttributes.has(processed, at: url) }

    public static func markProcessed(_ url: URL) {
        ExtendedAttributes.set(processed, data: Data("1".utf8), at: url)
    }

    /// The app that downloaded or received the file, from macOS's quarantine record.
    /// AirDrop records `sharingd`. Format: `flags;hex-time;agent;uuid`.
    public static func quarantineAgent(_ url: URL) -> String? {
        guard let data = ExtendedAttributes.data(quarantine, at: url),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return parseQuarantineAgent(value)
    }

    public static func parseQuarantineAgent(_ value: String) -> String? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let agent = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return agent.isEmpty ? nil : agent
    }

    public static func isAirDrop(_ url: URL) -> Bool {
        quarantineAgent(url) == "sharingd"
    }

    /// macOS marks its own screenshots with this Spotlight attribute.
    public static func isMacScreenshot(_ url: URL) -> Bool {
        ExtendedAttributes.has(isScreenCapture, at: url)
    }

    /// "Where from" is what Finder's Get Info shows and Spotlight searches. Linux keeps one origin URL.
    public static func setWhereFroms(_ values: [String], at url: URL) {
        #if os(Linux)
        if let link = values.first(where: { $0.contains("://") }) {
            ExtendedAttributes.set(xdgOrigin, data: Data(link.utf8), at: url)
        }
        #else
        guard !values.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        else { return }
        ExtendedAttributes.set(whereFroms, data: data, at: url)
        #endif
    }

    public static func whereFroms(_ url: URL) -> [String] {
        #if os(Linux)
        return ExtendedAttributes.data(xdgOrigin, at: url).map { [String(decoding: $0, as: UTF8.self)] } ?? []
        #else
        guard let data = ExtendedAttributes.data(whereFroms, at: url),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return list
        #endif
    }

    /// The file's tags: Finder tags on a Mac, `user.xdg.tags` on Linux.
    public static func tags(at url: URL) -> [String] {
        #if os(Linux)
        return ExtendedAttributes.data(xdgTags, at: url)
            .map { String(decoding: $0, as: UTF8.self).split(separator: ",").map(String.init) } ?? []
        #elseif canImport(Darwin)
        return (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        #else
        return []
        #endif
    }

    /// Finder tags on a Mac; `user.xdg.tags` (comma-separated, what Dolphin and Baloo use) on Linux.
    public static func addFinderTags(_ tags: [String], at url: URL) {
        guard !tags.isEmpty else { return }
        #if os(Linux)
        let existing = ExtendedAttributes.data(xdgTags, at: url)
            .map { String(decoding: $0, as: UTF8.self).split(separator: ",").map(String.init) } ?? []
        let merged = existing + tags.filter { !existing.contains($0) }
        if merged != existing { ExtendedAttributes.set(xdgTags, data: Data(merged.joined(separator: ",").utf8), at: url) }
        #elseif canImport(Darwin)
        let existing = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        var merged = existing
        for tag in tags where !merged.contains(tag) { merged.append(tag) }
        guard merged != existing else { return }
        // URLResourceValues.tagNames is read-only in Swift; NSURL can set it.
        try? (url as NSURL).setResourceValue(merged, forKey: .tagNamesKey)
        #endif
    }
}
