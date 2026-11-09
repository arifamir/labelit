import Foundation

public protocol Namer: Sendable {
    func name(_ facts: FileFacts) async -> NamingResult
}

/// Detects what kind of file this is from the facts alone. Shared by every namer.
public enum KindDetector {
    static let receiptWords = try! NSRegularExpression(
        pattern: #"\b(total|subtotal|amount due|amount paid|receipt|invoice|order (number|#|no)|vat|tax|payment method|grand total)\b"#,
        options: [.caseInsensitive])
    static let money = try! NSRegularExpression(
        pattern: #"(?:[$€£¥₹৳]|\b(?:usd|eur|gbp|bdt|inr|aed|sar)\b)\s?\d[\d,]*(?:[.,]\d{2})?|\d[\d,]*[.,]\d{2}\s?(?:[$€£¥₹৳]|\b(?:usd|eur|gbp|bdt|inr|aed|sar)\b)"#,
        options: [.caseInsensitive])
    static let errorWords = try! NSRegularExpression(
        pattern: #"\b(error|failed|failure|exception|denied|declined|unable to|could not|couldn['’]t|not found|fatal|crash(ed)?|traceback|panic|invalid|forbidden|timed? ?out|unauthori[sz]ed|refused|segmentation fault)\b"#,
        options: [.caseInsensitive])

    public static func detect(_ facts: FileFacts) -> FileKind {
        let text = facts.analysis.fullText
        if isReceipt(text) { return .receipt }
        if facts.isDocument { return .document }
        let isScreen = facts.isScreen
        if isScreen {
            if errorLine(in: facts.analysis.lines) != nil { return .error }
            return .ui
        }
        if facts.isVideo { return .video }
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let looksLikeDocument = facts.analysis.labels.contains {
            ["document", "printed_page", "paper", "text"].contains($0.name) && $0.confidence > 0.5
        }
        if wordCount > 60 || (looksLikeDocument && wordCount > 15) {
            // Lots of text, but the describer sees a thing, not paper: the label on a TV, a router, a washing machine.
            if let seen = facts.analysis.descriptions.first(where: { $0 != "selfie" }), !PhotoWords.paper.contains(seen) {
                return .photo
            }
            return .document
        }
        return .photo
    }

    public static func isReceipt(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return receiptWords.numberOfMatches(in: text, range: range) >= 1
            && money.numberOfMatches(in: text, range: range) >= 2
    }

    /// The screen's error message, when the error is the point of the screenshot: the screen has little text, or the
    /// line stands out (top half, larger than the body). A long page that merely mentions "declined" or "failed" (docs,
    /// an article, a README) isn't an error screenshot.
    public static func errorLine(in lines: [TextLine]) -> TextLine? {
        let errors = lines.filter { line in
            errorWords.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) != nil
        }
        guard !errors.isEmpty else { return nil }
        let words = lines.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        if words <= 60 { return errors.first }
        let heights = lines.map(\.height).sorted()
        let median = heights[heights.count / 2]
        return errors.first { $0.top < 0.5 && $0.height >= median * 1.15 }
    }
}

/// Builds names from Vision's findings and the capture context. Always available, never slow.
public struct RuleNamer: Namer {
    /// Vision labels too generic to be worth a place in a file name.
    static let genericLabels: Set<String> = [
        "outdoor", "indoor", "structure", "material", "textile", "art", "text", "document", "printed_page",
        "people", "adult", "land", "plant", "machine", "wood_processed", "conveyance", "consumer_electronics",
        "screenshot", "rectangle", "pattern", "line", "circle", "furniture", "liquid", "water_body", "sky",
        "blue_sky", "cloudy", "night_sky", "illustrations", "cartoon", "electronics", "computer", "monitor",
        "paper", "container", "sign", "shelf", "wall", "floor", "room", "interior_room", "light",
    ]

    /// Suffixes browsers and apps add to window titles.
    static let titleNoise = [
        " - Google Chrome", " — Google Chrome", " - Chromium", " - Brave", " - Microsoft Edge", " — Mozilla Firefox",
        " - Mozilla Firefox", " — Firefox Developer Edition", " - Arc", " — Safari", " - Safari", " - Slack",
        " | Slack", " - Visual Studio Code", " — Visual Studio Code", " - Cursor", " — Cursor", " - Zed",
    ]

    public init() {}

    public func name(_ facts: FileFacts) async -> NamingResult {
        let kind = KindDetector.detect(facts)
        return NamingResult(slug: slug(for: facts, kind: kind), kind: kind, namer: .rules)
    }

    func slug(for facts: FileFacts, kind: FileKind) -> String {
        switch kind {
        case .receipt: return receiptSlug(facts)
        case .error: return errorSlug(facts)
        case .ui, .screenshot: return screenSlug(facts)
        case .document: return documentSlug(facts)
        case .photo, .video, .other: return photoSlug(facts, kind: kind)
        }
    }

    private func receiptSlug(_ facts: FileFacts) -> String {
        let lines = facts.analysis.lines
        // The merchant is usually the first prominent line with letters in it.
        let merchant = lines.prefix(6)
            .filter { $0.text.rangeOfCharacter(from: .letters) != nil && !$0.text.contains(":") }
            .max { $0.height < $1.height }
            .map { Slug.make($0.text, maxWords: 3, maxLength: 25) } ?? ""
        var amount = ""
        for line in lines where line.text.localizedCaseInsensitiveContains("total")
            && !line.text.localizedCaseInsensitiveContains("subtotal") {
            if let value = firstMoney(in: line.text) { amount = value }
        }
        if amount.isEmpty, let lastMoney = lines.compactMap({ firstMoney(in: $0.text) }).last { amount = lastMoney }
        return ["receipt", merchant, amount].filter { !$0.isEmpty }.joined(separator: "-")
    }

    private func firstMoney(in text: String) -> String? {
        guard let match = KindDetector.money.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        let digits = text[range].filter { $0.isNumber || $0 == "." || $0 == "," }
        let normalized = digits.replacingOccurrences(of: ",", with: ".")
        return normalized.isEmpty ? nil : normalized.replacingOccurrences(of: ".", with: "-")
    }

    private func errorSlug(_ facts: FileFacts) -> String {
        guard let line = KindDetector.errorLine(in: facts.analysis.lines) else { return "error" }
        // The line always contains an error word ("declined", "failed"…), so it reads as an error already.
        var slug = Slug.make(line.text, maxWords: 6, maxLength: 50)
        if let app = appSlug(facts), !slug.contains(app) { slug = app + "-" + slug }
        return slug
    }

    private func screenSlug(_ facts: FileFacts) -> String {
        if let title = cleanTitle(facts.context?.windowTitle) {
            var slug = Slug.make(title, maxWords: 6, maxLength: 50)
            // The site first when the title doesn't name it: github-arifamir-labelit.
            if let site = Self.site(of: facts), !slug.isEmpty, !slug.split(separator: "-").contains(Substring(site)) {
                slug = Slug.make(site + " " + slug, maxWords: 7, maxLength: 55)
            }
            if !slug.isEmpty {
                if let app = appSlug(facts), !slug.contains(app), !isBrowser(facts) { return app + "-" + slug }
                return slug
            }
        }
        if let site = Self.site(of: facts) {
            let heading = headingSlug(facts, maxWords: 4)
            return [site, heading].filter { !$0.isEmpty }.joined(separator: "-")
        }
        // The screen's own title (a page's headline and the line under it), when one stands out.
        let heading = DocumentReading.screenTitle(in: facts.analysis.lines).map { DocumentReading.slug($0) }
            ?? headingSlug(facts, maxWords: 5)
        let app = appSlug(facts)
        if !heading.isEmpty {
            if let app, !heading.contains(app) { return app + "-" + heading }
            return heading
        }
        return app.map { $0 + "-screenshot" } ?? "screenshot"
    }

    /// What the document is, then its subject: certificate-building-modern-web-applications-go. The subject is the
    /// document's own title when it has a meaningful one, else the page's main heading.
    private func documentSlug(_ facts: FileFacts) -> String {
        let lines = facts.analysis.lines
        let subject = facts.meaningfulTitle.map { DocumentReading.slug($0) }
            ?? DocumentReading.heading(in: lines).map { DocumentReading.slug($0) }
            ?? headingSlug(facts, maxWords: 6)
        var parts: [String] = []
        if let type = DocumentReading.type(in: lines), !subject.split(separator: "-").contains(Substring(type)) {
            parts.append(type)
        }
        if !subject.isEmpty { parts.append(subject) }
        return parts.isEmpty ? "document" : Slug.make(parts.joined(separator: " "), maxWords: 7, maxLength: 60)
    }

    private func photoSlug(_ facts: FileFacts, kind: FileKind) -> String {
        let analysis = facts.analysis
        if !analysis.descriptions.isEmpty {
            var slug = Slug.make(analysis.descriptions.joined(separator: " "), maxWords: 6, maxLength: 45)
            if kind == .video && !slug.isEmpty { slug += "-video" }
            if !slug.isEmpty { return slug }
        }
        var words: [String] = []
        func add(_ word: String) {
            let slug = Slug.make(word.replacingOccurrences(of: "_", with: " "), maxWords: 2, maxLength: 20)
            if !slug.isEmpty && !words.contains(where: { $0.contains(slug) || slug.contains($0) }) { words.append(slug) }
        }
        if facts.metadata.isFrontCamera && analysis.faceCount > 0 { add("selfie") }
        analysis.animals.forEach(add)
        if analysis.faceCount == 1 && words.isEmpty { add("portrait") }
        if analysis.faceCount == 2 { add("two people") }
        if analysis.faceCount > 2 { add("group") }
        for label in analysis.labels where label.confidence >= 0.3 && !Self.genericLabels.contains(label.name) {
            if words.count >= 3 { break }
            add(label.name)
        }
        if words.isEmpty { return kind == .video ? "video" : "photo" }
        if kind == .video { words.append("video") }
        return words.joined(separator: "-")
    }

    /// Clock, battery and network text from a phone's status bar.
    static let statusText = try! NSRegularExpression(
        pattern: #"^\s*(\d{1,2}[:.]\d{2}(\s?[ap]m)?|\d{1,3}\s?%|lte|5g|4g|3g|wi-?fi|sos|e)\s*$"#,
        options: [.caseInsensitive])

    /// The screen's title: the first short line near the top (below a phone's status bar).
    /// Position works better than size here: OCR heights vary too much to spot headings reliably.
    /// Falls back to the biggest line when nothing short sits near the top.
    private func headingSlug(_ facts: FileFacts, maxWords: Int) -> String {
        // A phone screenshot's status bar (carrier, clock, battery) is its top ~6%.
        let skipTop = [.phone, .finder].contains(facts.source) && facts.metadata.isScreenshot ? 0.06 : 0
        let candidates = facts.analysis.lines.prefix(40).filter { line in
            guard line.top >= skipTop, line.text.count <= 80 else { return false }
            let letters = line.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            let range = NSRange(line.text.startIndex..., in: line.text)
            return letters >= 3 && Self.statusText.firstMatch(in: line.text, range: range) == nil
        }
        let wordCount = { (line: TextLine) in line.text.split(whereSeparator: \.isWhitespace).count }
        if let title = candidates.first(where: { $0.top < 0.3 && wordCount($0) <= 6 }) {
            let slug = Slug.make(title.text, maxWords: maxWords, maxLength: 45)
            if !slug.isEmpty { return slug }
        }
        guard let biggest = candidates.max(by: { $0.height < $1.height }) else { return "" }
        return Slug.make(biggest.text, maxWords: maxWords, maxLength: 45)
    }

    private func cleanTitle(_ title: String?) -> String? {
        guard var title, !title.isEmpty else { return nil }
        for noise in Self.titleNoise where title.hasSuffix(noise) {
            title = String(title.dropLast(noise.count))
        }
        // "owner/repo: A long description of it" (GitHub, and many sites): the name before the colon says it.
        if let colon = title.range(of: ": ") {
            let front = title[..<colon.lowerBound], rest = title[colon.upperBound...]
            if front.split(separator: " ").count <= 4 && rest.split(separator: " ").count > 5 { title = String(front) }
        }
        // "Pricing | Acme" → keep both, they're both useful.
        return title.trimmingCharacters(in: .whitespaces)
    }

    private func appSlug(_ facts: FileFacts) -> String? {
        guard let app = facts.context?.appName else { return nil }
        if ["Finder", "loginwindow", "Dock", "SystemUIServer", "LabelIt"].contains(app) { return nil }
        let slug = Slug.make(app, maxWords: 2, maxLength: 20)
        return slug.isEmpty ? nil : slug
    }

    /// Browsers are the apps a page address comes from.
    private func isBrowser(_ facts: FileFacts) -> Bool {
        if facts.context?.url != nil { return true }
        guard let id = facts.context?.bundleID else { return false }
        return BrowserBundleIDs.all.contains(id)
    }

    /// The site's name from the page address: "github" for https://github.com/…, "bbc" for www.bbc.co.uk.
    static func site(of facts: FileFacts) -> String? {
        guard let host = facts.context?.url.flatMap({ URL(string: $0)?.host() }) else { return nil }
        let name = host.replacingOccurrences(of: "www.", with: "").split(separator: ".").first.map(String.init) ?? ""
        let slug = Slug.make(name, maxWords: 1, maxLength: 20)
        return slug.isEmpty ? nil : slug
    }
}

public enum BrowserBundleIDs {
    public static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    public static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    public static let firefox: Set<String> = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition"]
    public static var all: Set<String> { safari.union(chromium).union(firefox) }
}
