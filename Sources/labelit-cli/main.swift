import Foundation
import LabelItCore
import LabelItEmbedding
import LabelItPlatform

let usage = """
labelit-cli — on-device names for screenshots and phone photos (\(NativePlatform.name))

  labelit-cli preview <folder> [limit] [--places]   what LabelIt would rename there; renames nothing
  labelit-cli rename <file>…                        rename these images or videos now (undo: labelit-cli undo)
  labelit-cli watch [folder…]                       rename new screenshots and phone files as they arrive
  labelit-cli undo                                  put the last rename back
  labelit-cli name <file> [--app A] [--title T] [--url U]   what LabelIt would call it (with that capture context)
  labelit-cli inspect <file>                        what the metadata reader and text reader see
  labelit-cli describe <file>…                      EmbeddingGemma 2's top matches and scores, for tuning
  labelit-cli status                                what's available on this computer
"""

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()
func path(_ argument: String) -> URL { URL(fileURLWithPath: (argument as NSString).expandingTildeInPath) }
func say(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }   // unbuffered, for watch

/// EmbeddingGemma 2, when its files are on this computer. Unloaded before exiting: llama.cpp aborts otherwise.
let describer = ModelFiles.locate().map { GemmaPhotoDescriber(files: $0) }
let reader = NativePlatform.reader()

func finish(_ status: Int32 = 0) async -> Never {
    await describer?.unload()
    exit(status)
}

func printStatus() {
    say("Platform:      \(NativePlatform.name)")
    say("Text reader:   \(NativePlatform.textReaderStatus)")
    say("Names by:      \(NativePlatform.namerDescription)\(NativePlatform.namerHint.map { " (\($0))" } ?? "")")
    say("Photos by:     \(describer == nil ? "built-in labels (EmbeddingGemma 2 not found in \(ModelFiles.folders.map(\.path)))" : "EmbeddingGemma 2")")
    say("History:       \(RenameLog.defaultURL.path)")
}

func describe(_ proposal: Proposal) -> String {
    let extra = proposal.moves.count > 1 ? "  (+ \((proposal.moves[1].to as NSString).lastPathComponent))" : ""
    return "\(proposal.originalName.padding(toLength: 24, withPad: " ", startingAt: 0)) → \(proposal.newName)  [\(proposal.kind.rawValue)]\(extra)"
}

switch command {
case "status":
    printStatus()

case "name":
    guard let file = args.first.map(path) else { say(usage); exit(1) }
    func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let context = CaptureContext(appName: option("--app"), windowTitle: option("--title"), url: option("--url"))
    let labeler = Labeler.native(describer: describer, log: RenameLog(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("labelit-name-\(UUID()).json")))
    let source: Source = reader.isSystemScreenshot(file) ? .screenshot : .finder
    guard let proposal = await labeler.plan(file, source: source, context: context.isEmpty ? nil : context) else {
        say("LabelIt doesn't name this kind of file."); await finish(1)
    }
    say("\(proposal.newName)  [\(proposal.kind.rawValue), \(proposal.namer.rawValue)]  (nothing renamed)")

case "inspect":
    guard let file = args.first.map(path) else { say(usage); exit(1) }
    say("metadata: \(await reader.metadata(of: file))")
    say("airdrop: \(FileMarkers.isAirDrop(file))  system screenshot: \(reader.isSystemScreenshot(file))")
    if let picture = await reader.picture(of: file, maxPixelSize: 3000) {
        say("picture: \(picture.width)×\(picture.height)")
        let analysis = await NativePlatform.understanding().analyze(picture, readText: true)
        if !analysis.labels.isEmpty {
            say("labels: \(analysis.labels.prefix(6).map { "\($0.name) \(String(format: "%.2f", $0.confidence))" })")
        }
        if !analysis.animals.isEmpty || analysis.faceCount > 0 { say("animals: \(analysis.animals)  faces: \(analysis.faceCount)") }
        for line in analysis.lines.prefix(12) {
            say(String(format: "  top %.3f  h %.4f  ", line.top, line.height) + line.text)
        }
    } else {
        say("picture: can't decode")
    }

case "describe":
    guard let describer else { say("EmbeddingGemma 2 isn't on this computer (looked in \(ModelFiles.folders.map(\.path)))"); exit(1) }
    for url in args.map(path) {
        guard let picture = await reader.picture(of: url, maxPixelSize: 1600) else { say("\(url.lastPathComponent): can't read"); continue }
        do {
            let result = try await describer.analyze(picture)
            say("\n\(url.lastPathComponent)  →  \(result.chosen.joined(separator: "-"))  (\(String(format: "%.2f", result.seconds))s)")
            for group in Vocabulary.Group.allCases {
                let top = (result.ranked[group] ?? []).prefix(4)
                    .map { "\($0.concept.slug) \(String(format: "%.3f z%.1f", $0.score, $0.zScore))" }
                say("  \(group.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(top.joined(separator: " | "))")
            }
        } catch {
            say("\(url.lastPathComponent): \(error)")
        }
    }

case "preview":
    guard let folder = args.first.map(path) else { say(usage); exit(1) }
    let limit = args.dropFirst().compactMap { Int($0) }.first ?? 20
    // A throwaway history: a preview renames nothing.
    let log = RenameLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("labelit-preview-\(UUID()).json"))
    let labeler = Labeler.native(describer: describer, log: log, settings: LabelerSettings(placeNames: args.contains("--places")))
    printStatus()
    let start = Date()
    let proposals = await labeler.planPastFiles(in: folder, limit: limit)
    proposals.forEach { say(describe($0)) }
    say(String(format: "%d files in %.1fs (nothing renamed)", proposals.count, Date().timeIntervalSince(start)))

case "rename":
    guard !args.isEmpty else { say(usage); exit(1) }
    let labeler = Labeler.native(describer: describer, log: RenameLog(fileURL: RenameLog.defaultURL))
    let entries = await labeler.renameChosen(args.map(path))
    for entry in entries { say("\(entry.originalName) → \(entry.newName)") }
    if entries.isEmpty { say("Nothing renamed: LabelIt renames images and videos\(NativePlatform.name == "macOS" ? ", and PDFs" : "").") }

case "undo":
    let log = RenameLog(fileURL: RenameLog.defaultURL)
    guard let last = await log.recent(50).first(where: \.canUndo) else { say("Nothing to undo."); exit(0) }
    do {
        try await log.undo(last.id)
        say("\(last.newName) → \(last.originalName)")
    } catch {
        say("Couldn't undo: \(error.localizedDescription)")
        await finish(1)
    }

case "watch":
    let home = FileManager.default.homeDirectoryForCurrentUser
    let folders = args.isEmpty ? ["Downloads", "Desktop", "Pictures", "Pictures/Screenshots"].map { home.appendingPathComponent($0) }
                                     .filter { FileManager.default.fileExists(atPath: $0.path) }
                               : args.map(path)
    let labeler = Labeler.native(describer: describer, log: RenameLog(fileURL: RenameLog.defaultURL))
    let watcher = FolderWatcher(folders: folders) { url in
        Task {
            if let entry = await labeler.handleNewFile(url) { say("\(entry.originalName) → \(entry.newName)") }
        }
    }
    watcher.start()
    printStatus()
    say("Watching \(folders.map(\.path).joined(separator: ", ")). Press Ctrl-C to stop.")
    // Ctrl-C: free the model first (llama.cpp aborts if the process exits with it loaded).
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        watcher.stop()
        Task { await finish() }
    }
    interrupt.resume()
    while true { try? await Task.sleep(for: .seconds(3600)) }

default:
    say(usage)
    await finish(command == "help" || command == "--help" ? 0 : 1)
}
await finish()
