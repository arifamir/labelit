import SwiftUI

struct WelcomeView: View {
    @Bindable var model: AppModel
    @State private var tick = 0
    /// The model download box, once it's been clicked; until then it follows the network (off on a hotspot).
    @State private var wantsModel: Bool?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var downloadsModel: Bool { wantsModel ?? model.modelPreselected }

    private func onDone() {
        if !model.hasOnboarded, downloadsModel, !model.modelIsReady { model.downloadModel() }
        model.hasOnboarded = true
        dismissWindow(id: WindowID.welcome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(model.hasOnboarded ? "LabelIt is running" : "Welcome to LabelIt").font(.title.bold())
                    Text("Screenshots and phone photos, named for what's in them.").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Example(before: "Screenshot 2026-11-08 at 10.41.07.png", after: "checkout-payment-declined_2026-11-08_104107.png")
                Example(before: "IMG_4821.HEIC", after: "dog-beach-sunset_2026-11-02.heic")
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(title: "Screen Recording",
                              detail: "For the ⌘⇧1 capture shortcut and window titles. You can skip this and still label macOS screenshots and phone files.",
                              granted: model.hasScreenRecording) { model.requestScreenRecording() }
                Toggle(isOn: $model.placeNames) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add the city to phone photos")
                        Text("Sends a photo's coordinates to Apple's location service. Off by default.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !model.modelIsReady { modelRow }
                if let hint = model.namerHint {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Better names with Apple Intelligence")
                            Text(hint).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open…") { model.openAppleIntelligenceSettings() }
                    }
                }
            }

            Text("Everything runs on this Mac. LabelIt only renames new screenshots and files with camera names like IMG_4821, and every rename can be undone from the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "tag").foregroundStyle(.tint)
                Text("LabelIt lives in the menu bar, near the clock. Can't see it? On a MacBook with a notch, icons that don't fit hide behind it: hold ⌘ and drag other icons out of the menu bar to make room. You can always reopen this window by opening LabelIt again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Label past phone files…") {
                    onDone()
                    openWindow(id: WindowID.pastFiles)
                }
                SettingsLink { Text("Settings…") }
                Spacer()
                Button(model.hasOnboarded ? "Done" : "Start") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background { Color.clear.id(tick) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick += 1 }
    }
}

extension WelcomeView {
    /// EmbeddingGemma 2: ticked at setup (unless the network costs money), downloaded in the background after Start.
    @ViewBuilder private var modelRow: some View {
        let title = "Describe photos with an AI model"
        let detail = "Names like dog-beach-sunset instead of dog. Runs on this Mac: a one-time \(AppModel.modelSize) download, in the background."
        if model.modelIsDownloading {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(model.modelSummary).font(.caption).foregroundStyle(.secondary)
                if case .downloading(let fraction) = model.modelStatus { ProgressView(value: fraction) }
            }
        } else if model.hasOnboarded {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download") { model.downloadModel() }
            }
        } else {
            Toggle(isOn: Binding(get: { downloadsModel }, set: { wantsModel = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail + (model.modelPreselected ? "" : " Off for now: this Mac is on a hotspot or in Low Data Mode."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct Example: View {
    let before: String
    let after: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(before).strikethrough().foregroundStyle(.secondary)
            Text(after)
        }
        .font(.system(.callout, design: .monospaced))
    }
}
