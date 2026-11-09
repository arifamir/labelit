import AppKit
import Network
import Observation
import ServiceManagement
import UserNotifications
import LabelItCore
import LabelItEmbedding
import LabelItPlatform

@Observable
final class AppModel {
    // MARK: Settings (persisted)

    var watchScreenshots: Bool { didSet { save(watchScreenshots, "watchScreenshots"); settingsChanged() } }
    var watchPhone: Bool { didSet { save(watchPhone, "watchPhone"); settingsChanged() } }
    var placeNames: Bool { didSet { save(placeNames, "placeNames"); settingsChanged() } }
    var finderTags: Bool { didSet { save(finderTags, "finderTags"); settingsChanged() } }
    var browserURL: Bool { didSet { save(browserURL, "browserURL") } }
    var captureHotKey: Bool { didSet { save(captureHotKey, "captureHotKey"); updateHotKey() } }
    var notifications: Bool { didSet { save(notifications, "notifications"); if notifications { requestNotifications() } } }
    var paused: Bool { didSet { save(paused, "paused"); restartWatching() } }
    var hasOnboarded: Bool { didSet { save(hasOnboarded, "hasOnboarded") } }
    var describePhotos: Bool { didSet { save(describePhotos, "describePhotos"); settingsChanged() } }
    var checkForUpdates: Bool { didSet { save(checkForUpdates, "checkForUpdates") } }
    /// A model download was started and hasn't finished or been cancelled: LabelIt carries on with it at launch.
    private var modelWanted: Bool { didSet { save(modelWanted, "modelWanted") } }
    /// Someone who skipped the model has been reminded once (or started a download), and isn't reminded again.
    private var modelReminded: Bool { didSet { save(modelReminded, "modelReminded") } }
    /// Where phone files are looked for. Downloads, Desktop and Pictures until changed in Settings.
    private(set) var phoneFolders: [URL] {
        didSet {
            UserDefaults.standard.set(phoneFolders.map(\.path), forKey: "phoneFolders")
            restartWatching()
        }
    }

    // MARK: EmbeddingGemma 2

    enum ModelStatus: Equatable {
        case missing
        case ready(ModelFiles.Located)
        case downloading(fraction: Double)
        case verifying
        case failed(String)
    }

    private(set) var modelStatus: ModelStatus = .missing
    /// The menu's "Better names for photos" row: shown with the one reminder, until it's answered.
    var modelOfferInMenu = false
    /// A phone hotspot (expensive) or Low Data Mode (constrained): setup doesn't tick the model download there.
    private(set) var network = (expensive: false, constrained: false)
    private let pathMonitor = NWPathMonitor()
    static let modelSize = ByteCountFormatter.string(fromByteCount: ModelFiles.totalBytes, countStyle: .file)
    private var describer: GemmaPhotoDescriber?
    private var downloader: ModelDownloader?
    /// Tells this download's events from those of one that was cancelled.
    private var downloadRun = 0

    var modelSummary: String {
        switch modelStatus {
        case .ready(let files):
            files.isDigUps ? "Using the copy DigUp downloaded" : "Downloaded"
        case .missing:
            "Not downloaded (\(Self.modelSize))"
        case .downloading(let fraction):
            "Downloading… \(Int(fraction * 100))%"
        case .verifying:
            "Checking the download…"
        case .failed(let message):
            "Download failed: \(message)"
        }
    }

    var modelIsReady: Bool {
        if case .ready = modelStatus { return true }
        return false
    }

    var modelIsDownloading: Bool {
        switch modelStatus {
        case .downloading, .verifying: true
        default: false
        }
    }

    /// Whether setup offers the model download ticked.
    var modelPreselected: Bool {
        ModelOffer.preselected(networkIsExpensive: network.expensive, networkIsConstrained: network.constrained)
    }

    var photosDescribedByModel: Bool {
        if case .ready = modelStatus { return describePhotos }
        return false
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastMessage = "Couldn't change Launch at Login: \(error.localizedDescription)"
            }
        }
    }

    // MARK: State

    private(set) var recent: [RenameEntry] = []
    /// Bumped when someone opens LabelIt while it's running; the menu bar icon's view then opens the LabelIt window.
    var showRequests = 0
    var lastMessage: String?
    private(set) var isCapturing = false

    var namerDescription: String {
        NativePlatform.namerDescription
    }
    var namerHint: String? { NativePlatform.namerHint }

    var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Every folder being watched right now: the screenshot folder and the phone folders that exist (a folder on a
    /// disk that isn't plugged in is picked up when it's mounted).
    var watchedFolders: [URL] {
        var folders: [URL] = []
        if watchScreenshots { folders.append(ScreenCapturer.screenshotFolder) }
        if watchPhone { folders += phoneFolders.filter(Self.exists) }
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    var foldersAreDefault: Bool { phoneFolders.map(\.path) == WatchFolders.defaults().map(\.path) }

    static func exists(_ folder: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    // MARK: Folders

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Choose folders where photos and videos from your phone arrive."
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let result = WatchFolders.adding(panel.urls, to: phoneFolders)
        phoneFolders = result.folders
        lastMessage = result.rejected.isEmpty ? nil
            : result.rejected.map { "\($0.folder.lastPathComponent) \($0.reason)." }.joined(separator: " ")
    }

    func removeFolder(_ folder: URL) {
        phoneFolders.removeAll { $0.path == folder.path }
    }

    func restoreDefaultFolders() {
        phoneFolders = WatchFolders.defaults()
        lastMessage = nil
    }

    let log = RenameLog(fileURL: RenameLog.defaultURL)
    let updater = Updater()
    let labeler: Labeler
    private var watcher: FolderWatcher?
    private var hotKey: HotKey?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "watchScreenshots": true, "watchPhone": true, "placeNames": false, "finderTags": true,
            "browserURL": true, "captureHotKey": true, "notifications": true, "paused": false, "hasOnboarded": false,
            "describePhotos": true, "modelWanted": false, "modelReminded": false, "checkForUpdates": true,
        ])
        watchScreenshots = defaults.bool(forKey: "watchScreenshots")
        watchPhone = defaults.bool(forKey: "watchPhone")
        placeNames = defaults.bool(forKey: "placeNames")
        finderTags = defaults.bool(forKey: "finderTags")
        browserURL = defaults.bool(forKey: "browserURL")
        captureHotKey = defaults.bool(forKey: "captureHotKey")
        notifications = defaults.bool(forKey: "notifications")
        paused = defaults.bool(forKey: "paused")
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        describePhotos = defaults.bool(forKey: "describePhotos")
        checkForUpdates = defaults.bool(forKey: "checkForUpdates")
        modelWanted = defaults.bool(forKey: "modelWanted")
        modelReminded = defaults.bool(forKey: "modelReminded")
        phoneFolders = (defaults.stringArray(forKey: "phoneFolders")?.map { URL(fileURLWithPath: $0, isDirectory: true) })
            ?? WatchFolders.defaults()
        labeler = Labeler.native(log: log)
    }

    func start() {
        // On by default, so ask once at launch (macOS shows the prompt only the first time).
        if notifications { requestNotifications() }
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.modelOfferCategory,
                                   actions: [UNNotificationAction(identifier: Self.downloadAction, title: "Download (\(Self.modelSize))")],
                                   intentIdentifiers: []),
        ])
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let network = (expensive: path.isExpensive, constrained: path.isConstrained)
            Task { @MainActor in self?.network = network }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        refreshModel()
        // A download that was under way when LabelIt quit (or the Mac restarted) carries on where it stopped.
        if modelWanted, !modelIsReady { downloadModel() }
        updater.startChecking { [weak self] in self?.checkForUpdates ?? false }
        settingsChanged()
        updateHotKey()
        Task { await refresh() }
        // A watched folder on an external disk: start watching it when the disk is plugged in, stop when it goes.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartWatching() }
            }
        }
    }

    // MARK: Actions

    func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        // Read the context before the crosshair appears: the app in front is what's being captured.
        let context = ContextReader.current(includeURL: browserURL)
        Task {
            defer { isCapturing = false }
            await closeMenuBarMenu()
            guard let temp = await ScreenCapturer.captureInteractive() else { return }
            do {
                let entry = try await labeler.labelCapture(temp, context: context, into: ScreenCapturer.screenshotFolder)
                await refresh()
                notify(entry)
            } catch {
                lastMessage = "Couldn't save the screenshot: \(error.localizedDescription)"
            }
        }
    }

    /// Closes LabelIt's menu bar menu, when Capture was clicked there, and waits for it to fade out: otherwise the menu
    /// is in the screenshot.
    private func closeMenuBarMenu() async {
        let menus = NSApp.windows.filter { window in
            window.isVisible && window is NSPanel && !window.className.contains("StatusBar")
                && window.level.rawValue > NSWindow.Level.normal.rawValue
        }
        guard !menus.isEmpty else { return }
        // Close it as a click on the icon does, so SwiftUI knows it's closed. Closing the window itself leaves SwiftUI
        // thinking the menu is open, and the next click on the icon does nothing.
        if let button = NSApp.windows.lazy.filter({ $0.className.contains("StatusBar") })
            .compactMap({ $0.contentView.flatMap(Self.statusButton) }).first {
            button.performClick(nil)
        } else {
            menus.forEach { $0.close() }
        }
        try? await Task.sleep(for: .milliseconds(250))
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap(statusButton).first
    }

    func undo(_ entry: RenameEntry) {
        Task {
            do {
                try await log.undo(entry.id)
                lastMessage = nil
            } catch {
                lastMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    func reveal(_ entry: RenameEntry) {
        let path = entry.undone ? entry.primary.from : entry.primary.to
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func open(_ entry: RenameEntry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.undone ? entry.primary.from : entry.primary.to))
    }

    /// Finder's right-click → Rename with LabelIt.
    func renameChosen(_ urls: [URL]) {
        Task {
            let entries = await labeler.renameChosen(urls)
            await refresh()
            if entries.count == 1 {
                notify(entries[0])
            } else if notifications {
                let content = UNMutableNotificationContent()
                if entries.isEmpty {
                    content.title = "Nothing renamed"
                    content.body = "LabelIt renames images, videos and PDFs."
                } else {
                    content.title = "Renamed \(entries.count) files"
                    content.body = entries.prefix(3).map(\.newName).joined(separator: "\n")
                        + (entries.count > 3 ? "\n…" : "")
                }
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
    }

    func installUpdate() {
        guard let release = updater.available else { return }
        Task { await updater.install(release) }
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func openAppleIntelligenceSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
    }

    func refresh() async {
        recent = await log.recent(30)
    }

    // MARK: Model

    /// Finds the model files (LabelIt's download, DigUp's, or the Hugging Face cache) and hands the describer to the labeler.
    func refreshModel() {
        guard let files = ModelFiles.locate() else {
            if case .ready = modelStatus { modelStatus = .missing }
            return
        }
        modelStatus = .ready(files)
        if case .some = describer { return }   // already set up; the files don't move while LabelIt runs
        let describer = GemmaPhotoDescriber(files: files)
        self.describer = describer
        Task { await labeler.update(describer: describer) }
    }

    func downloadModel() {
        guard !modelIsDownloading else { return }
        modelWanted = true
        modelReminded = true
        modelOfferInMenu = false
        modelStatus = .downloading(fraction: 0)
        downloadRun += 1
        let run = downloadRun
        let downloader = ModelDownloader { [weak self] state in
            Task { @MainActor in
                guard let self, self.downloadRun == run else { return }
                self.downloadChanged(state)
            }
        }
        self.downloader = downloader
        downloader.start()
    }

    func cancelDownload() {
        modelWanted = false
        downloadRun += 1
        downloader?.cancel()
        downloader = nil
        modelStatus = .missing
    }

    private func downloadChanged(_ state: ModelDownloader.State) {
        switch state {
        case .idle: break
        case .downloading(let received, let total):
            modelStatus = .downloading(fraction: total > 0 ? Double(received) / Double(total) : 0)
        case .verifying: modelStatus = .verifying
        case .finished:
            downloader = nil
            modelWanted = false
            refreshModel()
        case .failed(let message):
            downloader = nil
            modelStatus = .failed(message)
        }
    }

    /// llama.cpp aborts if the process exits with the model loaded, so quitting frees it first.
    func prepareToQuit() async {
        await downloader?.stop()   // keeps the partial download for the next launch
        await describer?.shutDown()
    }

    // MARK: Plumbing

    private func save(_ value: Bool, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    private func settingsChanged() {
        let settings = LabelerSettings(screenshots: watchScreenshots, phone: watchPhone,
                                       placeNames: placeNames, finderTags: finderTags, describePhotos: describePhotos)
        Task { await labeler.update(settings: settings) }
        restartWatching()
    }

    private func restartWatching() {
        watcher?.stop()
        watcher = nil
        guard !paused, !watchedFolders.isEmpty else { return }
        let labeler = self.labeler
        let includeURL = browserURL
        let watcher = FolderWatcher(folders: watchedFolders, maxDepth: WatchFolders.depth) { [weak self] url in
            Task {
                let entry = await labeler.handleNewFile(url) {
                    await MainActor.run { ContextReader.current(includeURL: includeURL) }
                }
                guard let entry else { return }
                await self?.refresh()
                await self?.notify(entry)
                await self?.remindAboutModel(after: entry)
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func updateHotKey() {
        hotKey = captureHotKey ? HotKey { [weak self] in self?.capture() } : nil
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    nonisolated static let modelOfferCategory = "model-offer"
    nonisolated static let downloadAction = "download"

    /// The one reminder, for someone who skipped the model: when a phone photo is named without it.
    private func remindAboutModel(after entry: RenameEntry) {
        guard ModelOffer.shouldRemind(after: entry.source, modelAvailable: modelIsReady, downloading: modelIsDownloading,
                                      describePhotos: describePhotos, onboarded: hasOnboarded,
                                      alreadyReminded: modelReminded) else { return }
        modelReminded = true
        modelOfferInMenu = true
        guard notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Better names for photos"
        content.body = "LabelIt can describe what's in your photos with an AI model that runs on this Mac. "
            + "Download it once (\(Self.modelSize))."
        content.categoryIdentifier = Self.modelOfferCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "model-offer", content: content, trigger: nil))
    }

    private func notify(_ entry: RenameEntry) {
        guard notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = switch entry.source {
        case .capture, .screenshot: "Screenshot labeled"
        case .phone: entry.moves.count > 1 ? "Live Photo labeled" : "Phone file labeled"
        case .finder: "Renamed"
        }
        content.body = entry.newName
        let request = UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
