import SwiftUI
import LabelItCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("Sources", systemImage: "tray.and.arrow.down") { SourcesPane(model: model) }
            Tab("Naming", systemImage: "character.cursor.ibeam") { NamingPane(model: model) }
            Tab("Permissions", systemImage: "lock.shield") { PermissionsPane(model: model) }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct SourcesPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.watchScreenshots) {
                    Text("macOS screenshots")
                    Text("⌘⇧3, ⌘⇧4 and ⌘⇧5, saved to \(ScreenCapturer.screenshotFolder.lastPathComponent)")
                }
                Toggle(isOn: $model.watchPhone) {
                    Text("Photos and videos from iPhone or iPad")
                    Text("AirDrop, Continuity Camera and Image Capture, in the folders below. Only files with camera names like IMG_4821 are renamed.")
                }
                Toggle(isOn: $model.captureHotKey) {
                    Text("Capture shortcut ⌘⇧1")
                    Text("Takes a screenshot and saves which app, window and web page it came from.")
                }
            }
            Section {
                Toggle("Notify me when a file is labeled", isOn: $model.notifications)
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
            Section {
                Toggle(isOn: $model.checkForUpdates) {
                    Text("Check for updates")
                    Text("Once a day, asks GitHub for the newest version number. Nothing about you or your files is sent.")
                }
                HStack {
                    Text(updateStatus).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if model.updater.available != nil {
                        Button("Update") { model.installUpdate() }
                    } else {
                        Button("Check Now") { Task { await model.updater.check() } }
                            .disabled(model.updater.state == .checking || isUpdating)
                    }
                }
            }
            Section {
                if model.watchScreenshots {
                    FolderRow(folder: ScreenCapturer.screenshotFolder, prefix: "Screenshots · ", onRemove: nil)
                }
                ForEach(model.phoneFolders, id: \.self) { folder in
                    FolderRow(folder: folder, missing: !AppModel.exists(folder), onRemove: { model.removeFolder(folder) })
                        .opacity(model.watchPhone ? 1 : 0.5)
                }
                if model.phoneFolders.isEmpty {
                    Text("No folders: phone files aren't looked for.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Add Folder…") { model.addFolders() }
                    if !model.foldersAreDefault {
                        Button("Restore Defaults") { model.restoreDefaultFolders() }
                    }
                }
                if let message = model.lastMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                if model.paused { Text("Paused — nothing is being renamed.").foregroundStyle(.orange) }
            } header: {
                Text("Folders")
            } footer: {
                Text("LabelIt looks two folders deep in each, so Downloads also covers Downloads/Phone/2026.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension SourcesPane {
    private var isUpdating: Bool {
        if case .updating = model.updater.state { return true }
        return false
    }

    private var updateStatus: String {
        let current = "LabelIt \(model.updater.currentVersion)"
        return switch model.updater.state {
        case .idle: current
        case .checking: "Checking…"
        case .upToDate: "\(current) is the newest version."
        case .available(let release): "LabelIt \(release.version) is available (you have \(model.updater.currentVersion))."
        case .updating(let step): step
        case .failed(let message): message
        }
    }
}

private struct NamingPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Names written by", value: model.namerDescription)
                if let hint = model.namerHint {
                    HStack {
                        Text(hint).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") { model.openAppleIntelligenceSettings() }
                    }
                }
            }
            Section {
                Toggle(isOn: $model.describePhotos) {
                    Text("Describe photos with EmbeddingGemma 2")
                    Text("Google DeepMind's open image model, on this Mac. Names like living-room, garden-sunny or car-wheel instead of photo. Uses about 1 GB of memory while naming photos, then unloads.")
                }
                HStack {
                    Text(model.modelSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    switch model.modelStatus {
                    case .missing, .failed:
                        Button("Download") { model.downloadModel() }
                    case .downloading(let fraction):
                        ProgressView(value: fraction).frame(width: 120)
                        Button("Cancel") { model.cancelDownload() }
                    case .verifying:
                        ProgressView().controlSize(.small)
                    case .ready(let files):
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([files.text]) }
                    }
                }
            } header: {
                Text("Photos")
            }
            Section {
                Toggle(isOn: $model.placeNames) {
                    Text("Add the place to phone photos")
                    Text("dog-on-beach_lisbon_2026-11-02.heic. Looks up the city with Apple's location service, so the photo's coordinates are sent to Apple. Everything else stays on this Mac.")
                }
                Toggle(isOn: $model.browserURL) {
                    Text("Save the web page address with screenshots")
                    Text("Asks Safari, Chrome, Arc, Brave or Edge for the current tab. macOS asks once per browser.")
                }
                Toggle(isOn: $model.finderTags) {
                    Text("Add a Finder tag")
                    Text("Screenshot, Error, Receipt, Photo… so you can filter in Finder.")
                }
            }
            Section("Examples") {
                Text("checkout-payment-declined_2026-11-08_104107.png")
                Text("receipt-corner-cafe-9-75_2026-11-02.heic")
                Text("living-room_2026-09-20.heic")
                Text("garden-sunny_lisbon_2026-11-02.heic  + .mov")
            }
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsPane: View {
    @Bindable var model: AppModel
    @State private var tick = 0

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Screen Recording",
                              detail: "Needed for the capture shortcut and to read window titles.",
                              granted: model.hasScreenRecording) { model.requestScreenRecording() }
                PermissionRow(title: "Files and Folders",
                              detail: "macOS asks the first time LabelIt renames something in Downloads, Desktop or Pictures.",
                              granted: nil) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                }
                PermissionRow(title: "Automation (browsers)",
                              detail: "Only for saving the web page address. macOS asks per browser.",
                              granted: nil) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            }
            Section {
                Text("LabelIt reads only new screenshots and phone files in the folders above. It renames files and adds tags; it never uploads, deletes or edits them, and never touches your Photos library. Every rename can be undone from the menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .background { Color.clear.id(tick) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick += 1 }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    /// nil: macOS asks on demand, nothing to check up front.
    let granted: Bool?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted == true ? "checkmark.circle.fill" : granted == false ? "circle" : "info.circle")
                .foregroundStyle(granted == true ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted != true {
                Button(granted == false ? "Allow…" : "Open…", action: action)
            }
        }
    }
}

/// A watched folder: its icon and name, where it is, and a remove button unless it's fixed (the screenshot folder).
private struct FolderRow: View {
    let folder: URL
    var prefix = ""
    var missing = false
    let onRemove: (() -> Void)?

    private var detail: String {
        missing ? "Not found — watched again when it's back"
                : prefix + folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.lastPathComponent)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(missing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop watching \(folder.lastPathComponent)")
            }
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }
}
