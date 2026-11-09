import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum Paths {
    /// The real path, symlinks resolved, as the file system reports events for it. Not `URL.resolvingSymlinksInPath()`:
    /// on macOS it turns /private/tmp/x into /tmp/x, while FSEvents reports /private/tmp/x.
    public static func canonical(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return path }   // doesn't exist (yet): keep it as given
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
