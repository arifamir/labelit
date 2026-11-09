import Foundation

/// Runs macOS's own interactive screenshot tool (crosshair / window picker) into a temporary file.
enum ScreenCapturer {
    /// Returns the captured image, or nil if the user pressed Escape.
    static func captureInteractive() async -> URL? {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("labelit-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", temp.path]
        let ok: Bool = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
        guard ok, let size = try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
        return temp
    }

    /// Where macOS saves screenshots (System Settings or ⌘⇧5 → Options), Desktop by default.
    static var screenshotFolder: URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
}
