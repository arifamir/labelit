import AppKit
import CoreGraphics
import LabelItCore

/// Reads what's on screen right now: the app in front, its window title and, for browsers, the page URL.
enum ContextReader {
    static func current(includeURL: Bool) -> CaptureContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return CaptureContext() }
        var context = CaptureContext(appName: app.localizedName, bundleID: app.bundleIdentifier)
        context.windowTitle = frontWindowTitle(pid: app.processIdentifier)
        if includeURL, let id = app.bundleIdentifier {
            context.url = browserURL(bundleID: id)
        }
        return context
    }

    /// Window titles are only visible with Screen Recording permission; without it this returns nil.
    private static func frontWindowTitle(pid: pid_t) -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // The list is front-to-back; the first normal-layer window of the app is the one in front.
        let window = windows.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                && !(($0[kCGWindowName as String] as? String) ?? "").isEmpty
        }
        return window?[kCGWindowName as String] as? String
    }

    /// Asks the browser for the current tab's URL. macOS asks the user once per browser.
    private static func browserURL(bundleID: String) -> String? {
        let script: String
        if BrowserBundleIDs.safari.contains(bundleID) {
            script = "tell application id \"\(bundleID)\" to get URL of current tab of front window"
        } else if BrowserBundleIDs.chromium.contains(bundleID) {
            script = "tell application id \"\(bundleID)\" to get URL of active tab of front window"
        } else {
            return nil // Firefox has no scripting support for this.
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard error == nil, let value = result?.stringValue, value.hasPrefix("http") else { return nil }
        return value
    }
}
