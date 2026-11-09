import SwiftUI
import LabelItCore

/// Preview, then rename, phone files that arrived before LabelIt was installed.
@Observable
final class PastFilesModel {
    enum Phase: Equatable { case idle, scanning(done: Int, total: Int), ready, applying, finished(renamed: Int) }

    var folder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    var proposals: [Proposal] = []
    var selected: Set<String> = []
    var phase: Phase = .idle
    var failures: [String] = []

    let appModel: AppModel

    init(appModel: AppModel) { self.appModel = appModel }

    func scan() {
        phase = .scanning(done: 0, total: 0)
        proposals = []
        selected = []
        failures = []
        let folder = self.folder
        Task {
            let found = await appModel.labeler.planPastFiles(in: folder) { done, total in
                Task { @MainActor in
                    if case .scanning = self.phase { self.phase = .scanning(done: done, total: total) }
                }
            }
            proposals = found
            selected = Set(found.map(\.id))
            phase = .ready
        }
    }

    func apply() {
        phase = .applying
        let chosen = proposals.filter { selected.contains($0.id) }
        Task {
            var renamed = 0
            for proposal in chosen {
                do {
                    let entry = try await appModel.labeler.apply(proposal)
                    renamed += entry.moves.count
                } catch {
                    failures.append("\(proposal.originalName): \(error.localizedDescription)")
                }
            }
            await appModel.refresh()
            phase = .finished(renamed: renamed)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            scan()
        }
    }
}

/// Creates a fresh scan each time the window opens.
struct PastFilesWindow: View {
    let appModel: AppModel
    @State private var model: PastFilesModel?

    var body: some View {
        Group {
            if let model { PastFilesView(model: model) } else { Color.clear }
        }
        .onAppear { model = PastFilesModel(appModel: appModel) }
        .onDisappear { model = nil }
    }
}

struct PastFilesView: View {
    @Bindable var model: PastFilesModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Label past phone files").font(.title2.bold())
                Text("Finds photos and videos from your iPhone or iPad that still have camera names, and shows what LabelIt would call them. Nothing is renamed until you click Rename.")
                    .foregroundStyle(.secondary)
                HStack {
                    Label(model.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                    Button("Change…") { model.chooseFolder() }
                        .disabled(isBusy)
                }
                .padding(.top, 4)
            }
            .padding(20)
            Divider()
            content
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 680, minHeight: 480)
        .task { if model.phase == .idle { model.scan() } }
    }

    private var isBusy: Bool {
        switch model.phase {
        case .scanning, .applying: return true
        default: return false
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .scanning:
            VStack(spacing: 10) {
                if case .scanning(let done, let total) = model.phase, total > 0 {
                    ProgressView(value: Double(done), total: Double(total)).frame(width: 260)
                    Text("Looking at \(done) of \(total)…").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("Looking for phone files…").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready where model.proposals.isEmpty:
            ContentUnavailableView("No phone files to label", systemImage: "checkmark.circle",
                                   description: Text("Nothing in this folder has a camera name like IMG_4821."))
        case .ready, .applying, .finished:
            List(model.proposals) { proposal in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { model.selected.contains(proposal.id) },
                        set: { isOn in
                            if isOn { model.selected.insert(proposal.id) } else { model.selected.remove(proposal.id) }
                        }))
                    .labelsHidden()
                    .disabled(model.phase != .ready)
                    Text(proposal.originalName)
                        .foregroundStyle(.secondary)
                        .frame(width: 170, alignment: .leading)
                        .lineLimit(1)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(proposal.newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if proposal.moves.count > 1 {
                        Text("+ video").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: proposal.moves[0].from))
                    } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
                    .help("Open \(proposal.originalName)")
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            switch model.phase {
            case .finished(let renamed):
                Label("Renamed \(renamed) files. You can undo any of them from the menu bar.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !model.failures.isEmpty {
                    Text("\(model.failures.count) skipped").foregroundStyle(.orange).help(model.failures.joined(separator: "\n"))
                }
                Spacer()
                Button("Done") { dismissWindow(id: WindowID.pastFiles) }.keyboardShortcut(.defaultAction)
            default:
                if !model.proposals.isEmpty {
                    Button(model.selected.count == model.proposals.count ? "Select None" : "Select All") {
                        if model.selected.count == model.proposals.count { model.selected = [] }
                        else { model.selected = Set(model.proposals.map(\.id)) }
                    }
                    .disabled(model.phase != .ready)
                    Text("\(model.selected.count) of \(model.proposals.count) selected").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismissWindow(id: WindowID.pastFiles) }
                Button(model.phase == .applying ? "Renaming…" : "Rename \(model.selected.count) Files") { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.phase != .ready || model.selected.isEmpty)
            }
        }
    }
}
