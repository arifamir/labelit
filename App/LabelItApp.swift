import SwiftUI

@main
struct LabelItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("LabelIt", id: WindowID.welcome) {
            WelcomeView(model: delegate.model)
        }
        .windowResizability(.contentSize)

        Window("Label Past Files", id: WindowID.pastFiles) {
            PastFilesWindow(appModel: delegate.model)
        }
        .defaultSize(width: 760, height: 560)

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

enum WindowID {
    static let welcome = "welcome"
    static let pastFiles = "past-files"
}

/// The menu bar icon. It's the one view that exists from launch, so it opens the LabelIt window: on first launch, and
/// whenever LabelIt is opened again while it's running (it has no Dock icon, and the menu bar icon can be hidden
/// behind a MacBook's notch).
private struct MenuBarIcon: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.paused ? "tag.slash" : "tag")
            .task {
                guard !model.hasOnboarded else { return }
                show()
            }
            .onChange(of: model.showRequests) { show() }
    }

    private func show() {
        NSApp.activate()
        openWindow(id: WindowID.welcome)
    }
}

extension Notification.Name {
    /// Sent by a second copy of LabelIt to the one already running, before it quits.
    static let labelItShow = Notification.Name("com.kodberry.labelit.show")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One LabelIt at a time: two would rename the same files. A second copy (another build, or one started from a
        // different folder) shows the running one and quits.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(.labelItShow, object: nil, deliverImmediately: true)
            exit(0)   // nothing started yet: no watcher, no model to free
        }
        DistributedNotificationCenter.default().addObserver(forName: .labelItShow, object: nil, queue: .main) { [model] _ in
            MainActor.assumeIsolated { model.showRequests += 1 }
        }
        model.start()
        // Finder's right-click → Rename with LabelIt (the NSServices entry in Info.plist).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// The service Finder calls with the picked files. macOS launches LabelIt for it if it isn't running.
    @objc func renameFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files to rename." as NSString
            return
        }
        model.renameChosen(urls)
    }

    /// Opened again while running (double-click in Finder, Spotlight, Launchpad): show the LabelIt window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showRequests += 1
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
