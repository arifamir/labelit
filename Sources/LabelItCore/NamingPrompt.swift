import Foundation

/// What a language model is told when it names a file, and how its answer is cleaned up. Shared by every namer that
/// uses a model (Apple Intelligence on a Mac; a local model elsewhere), so they all see the same facts.
public enum NamingPrompt {
    public static let instructions = """
    You name files on a user's computer so they can find them later. You get facts about one file: \
    what kind it is, which app or website it came from, text read from it, and objects seen in it. \
    Reply with a short, specific name using only those facts. When a window title or website is given, \
    say which page or app it is; otherwise start with the screen's main heading when one is given. Other text \
    read from the picture only adds detail. Prefer the most distinctive \
    subject: the product, site, page, error, merchant, animal or scene. Never invent details.
    """

    /// Words that describe the file, not what's in it: every photo is a photo.
    public static let filler: Set<String> = ["photo", "picture", "image", "pic", "phone", "camera", "iphone", "file",
                                      "screenshot", "snapshot", "conveyance", "structure"]

    public static func dropFiller(_ slug: String) -> String {
        let words = slug.split(separator: "-").map(String.init)
        let kept = words.filter { !filler.contains($0) }
        return kept.isEmpty ? slug : kept.joined(separator: "-")
    }

    /// Whether a model's name says enough. A document's name must carry at least one word of its main heading:
    /// "certificate-of-completion" alone doesn't say what the certificate is for.
    public static func isSpecificEnough(_ slug: String, for facts: FileFacts) -> Bool {
        let words = Set(slug.split(separator: "-"))
        // A browser screenshot's name must be about that page: share a word with its title or site. Otherwise the
        // model went by some text inside the page (it latches onto the most prominent phrase), not by what the page is.
        if let context = facts.context, context.url != nil {
            let host = context.url.flatMap { URL(string: $0)?.host() } ?? ""
            let pageWords = Set(Slug.make((context.windowTitle ?? "") + " " + host.replacingOccurrences(of: ".", with: " "),
                                          maxWords: 40, maxLength: 400).split(separator: "-"))
            if !pageWords.isEmpty && pageWords.isDisjoint(with: words) { return false }
        } else if !facts.isDocument, facts.isScreen, let title = DocumentReading.screenTitle(in: facts.analysis.lines) {
            // A screen with a clear title: the name must mention it, not a badge or caption elsewhere on screen.
            let titleWords = Set(DocumentReading.slug(title.heading + " " + (title.subtitle ?? ""), maxWords: 20).split(separator: "-"))
            if !titleWords.isEmpty && titleWords.isDisjoint(with: words) { return false }
        }
        guard facts.isDocument, let heading = DocumentReading.heading(in: facts.analysis.lines) else { return true }
        let headingWords = Set(DocumentReading.slug(heading, maxWords: 12).split(separator: "-"))
        guard !headingWords.isEmpty else { return true }
        return !headingWords.isDisjoint(with: words)
    }

    public static func prompt(for facts: FileFacts, kind: FileKind) -> String {
        var lines: [String] = []
        let kindText: String = switch kind {
        case .error: "screenshot showing an error"
        case .ui: "screenshot of an app or website"
        case .screenshot: "screenshot"
        case .receipt: "receipt or order confirmation (include the merchant and total)"
        case .document: facts.isDocument
            // No example names here: the on-device model copies an example's words into its answer.
            ? "PDF document. Start the name with who issued it and the document type, then the subject from its main heading. Use only words that appear in the facts below"
            : "photo or scan of a document"
        case .photo: "photo"
        case .video: "video"
        case .other: "file"
        }
        lines.append("Kind: \(kindText)")
        if let title = facts.meaningfulTitle { lines.append("Document title: \(title.prefix(150))") }
        if !facts.isDocument, facts.isScreen, let title = DocumentReading.screenTitle(in: facts.analysis.lines) {
            lines.append("Main heading: \(title.heading.prefix(120))")
            if let subtitle = title.subtitle { lines.append("Subheading: \(subtitle.prefix(150))") }
        }
        if facts.isDocument {
            if let heading = DocumentReading.heading(in: facts.analysis.lines) { lines.append("Main heading: \(heading.prefix(150))") }
            if let type = DocumentReading.type(in: facts.analysis.lines) { lines.append("Document type: \(type)") }
        }
        if let context = facts.context {
            // A browser's name says nothing about the page (the model puts "google-chrome" in names): the site does.
            if let app = context.appName, context.url == nil { lines.append("App: \(app)") }
            if let title = context.windowTitle, !title.isEmpty { lines.append("Window title: \(title.prefix(150))") }
            if let url = context.url { lines.append("Website: \(url.prefix(150))") }
        }
        let analysis = facts.analysis
        if !analysis.descriptions.isEmpty {
            // EmbeddingGemma 2's reading is the most reliable fact about a photo; Vision's labels are
            // vaguer ("structure", "machine") and only muddy the name, so they're left out.
            lines.append("Main subject (reliable; base the name on this): \(analysis.descriptions.joined(separator: ", "))")
            if !analysis.animals.isEmpty { lines.append("Animals: \(analysis.animals.joined(separator: ", "))") }
        } else {
            if !analysis.animals.isEmpty { lines.append("Animals: \(analysis.animals.joined(separator: ", "))") }
            if analysis.faceCount > 0 { lines.append("People's faces: \(analysis.faceCount)") }
            let labels = analysis.labels
                .filter { $0.confidence >= 0.3 && !RuleNamer.genericLabels.contains($0.name) }
                .prefix(6)
                .map { $0.name.replacingOccurrences(of: "_", with: " ") }
            if !labels.isEmpty { lines.append("Seen in image: \(labels.joined(separator: ", "))") }
        }
        if let errorLine = KindDetector.errorLine(in: analysis.lines), kind == .error {
            lines.append("Error message: \(errorLine.text.prefix(200))")
        }
        if !analysis.lines.isEmpty {
            // Biggest text first: headings say more than body text. Stay well inside the context window.
            let ordered = analysis.lines.sorted { $0.height > $1.height }.prefix(25).map(\.text)
            var budget = 900
            var kept: [String] = []
            for text in ordered where budget > 0 {
                kept.append(String(text.prefix(budget)))
                budget -= text.count
            }
            lines.append("Text in image (largest first):\n" + kept.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }
}
