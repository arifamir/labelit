import SwiftUI
import LabelItCore

/// The panel that opens from the menu bar icon.
struct MenuView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    /// The recent renames' full height, measured: the list is that tall, up to `maxListHeight`, then scrolls.
    @State private var listHeight: CGFloat = 0
    private let maxListHeight: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            recentList
            if let update = UpdateRow(updater: model.updater, install: model.installUpdate) {
                Divider()
                update
            }
            if model.modelOfferInMenu, !model.modelIsReady, !model.modelIsDownloading {
                Divider()
                modelOffer
            }
            if let message = model.lastMessage {
                Divider()
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .task { await model.refresh() }
    }

    /// The one reminder about the photo model, for someone who skipped it at setup.
    private var modelOffer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Better names for photos", systemImage: "sparkles").font(.callout.weight(.semibold))
            Text("An AI model on this Mac can describe what's in your photos: dog-beach-sunset instead of dog. One-time download, \(AppModel.modelSize).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Download") { model.downloadModel() }
                    .buttonStyle(.borderedProminent)
                Button("Not now") { model.modelOfferInMenu = false }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LabelIt").font(.headline)
                Spacer()
                Toggle("Paused", isOn: $model.paused)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(model.paused ? "LabelIt isn't renaming new files" : "Pause renaming new files")
                Text(model.paused ? "Paused" : "On")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.capture()
            } label: {
                Label("Capture screenshot", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("1", modifiers: [.command, .shift])
            HStack(spacing: 4) {
                Image(systemName: model.namerHint == nil ? "sparkles" : "list.bullet.rectangle")
                Text("Names by \(model.namerDescription)" + (model.photosDescribedByModel ? " · photos by EmbeddingGemma 2" : ""))
                    .lineLimit(1)
                if model.namerHint != nil {
                    Button("Improve…") { model.openAppleIntelligenceSettings() }
                        .buttonStyle(.link)
                        .help(model.namerHint ?? "")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder private var recentList: some View {
        if model.recent.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tag").font(.title2).foregroundStyle(.tertiary)
                Text("Nothing labeled yet").font(.callout)
                Text("Take a screenshot or AirDrop a photo from your phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        } else {
            // A menu bar window takes its content's natural size, and a scroll view's natural height is next to
            // nothing: given only a maximum, the list collapses to a sliver. So it gets the rows' measured height.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.recent) { entry in
                        RecentRow(entry: entry, model: model)
                        Divider().padding(.leading, 40)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 1), maxListHeight))
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var footer: some View {
        HStack {
            Button("Label past files…") {
                NSApp.activate()
                openWindow(id: WindowID.pastFiles)
            }
            Spacer()
            Button("Settings…") {
                NSApp.activate()
                openSettings()
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(12)
    }
}

private struct RecentRow: View {
    let entry: RenameEntry
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(entry.undone ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.undone ? entry.originalName : entry.newName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(false)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if hovering {
                if entry.canUndo {
                    Button { model.undo(entry) } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Undo: rename back to \(entry.originalName)")
                }
                Button { model.reveal(entry) } label: { Image(systemName: "magnifyingglass") }
                    .help("Show in Finder")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(entry) }
        .help(entry.undone ? entry.primary.from : entry.primary.to)
    }

    private var subtitle: String {
        let time = entry.date.formatted(.relative(presentation: .named))
        if entry.undone { return "Undone · \(time)" }
        var parts = ["was \(entry.originalName)"]
        if entry.moves.count > 1 { parts.append("+ video") }
        if let app = entry.context?.appName { parts.append(app) }
        parts.append(time)
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch entry.kind {
        case .error: return "exclamationmark.octagon"
        case .ui, .screenshot: return "macwindow"
        case .receipt: return "receipt"
        case .document: return "doc.text"
        case .photo: return entry.moves.count > 1 ? "livephoto" : "photo"
        case .video: return "video"
        case .other: return "doc"
        }
    }
}

/// A newer LabelIt, an update under way, or one that failed. Nothing when there's no news.
struct UpdateRow: View {
    let updater: Updater
    let install: () -> Void

    init?(updater: Updater, install: @escaping () -> Void) {
        switch updater.state {
        case .available, .updating, .failed: break
        default: return nil
        }
        self.updater = updater
        self.install = install
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch updater.state {
            case .available(let release):
                Label("LabelIt \(release.version) is available", systemImage: "arrow.down.circle")
                    .font(.callout.weight(.semibold))
                HStack {
                    Button("Update") { install() }
                        .buttonStyle(.borderedProminent)
                    Button("What's New") { NSWorkspace.shared.open(release.notes) }
                }
                .controlSize(.small)
            case .updating(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.callout)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { updater.dismissFailure() }.controlSize(.small)
            default:
                EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
