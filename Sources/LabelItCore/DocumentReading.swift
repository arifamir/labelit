import Foundation

/// Reads a document's first page for naming: its main heading (which may wrap onto several lines) and what kind of
/// document it says it is.
public enum DocumentReading {
    /// The largest text in the top two-thirds of the page, with the lines next to it of the same size: a title that
    /// wraps ("Building Modern Web / Applications with Go") is one heading.
    public static func heading(in lines: [TextLine]) -> String? {
        guard let span = headingSpan(in: lines) else { return nil }
        return span.ordered[span.first...span.last].map(\.text).joined(separator: " ")
    }

    /// Where the main heading is: its lines in reading order, and their size.
    static func headingSpan(in lines: [TextLine]) -> (ordered: [TextLine], first: Int, last: Int, size: Double)? {
        let ordered = lines.sorted { $0.top < $1.top }
        let candidates = ordered.indices.filter { index in
            let line = ordered[index]
            return line.top < 0.66 && line.text.filter(\.isLetter).count >= 3 && !line.text.contains(":")
        }
        guard let main = candidates.max(by: { ordered[$0].height < ordered[$1].height }) else { return nil }
        let size = ordered[main].height
        // A line joins the heading when it's the same size and right above or below it.
        func sameSize(_ line: TextLine) -> Bool { abs(line.height - size) <= size * 0.25 && !line.text.contains(":") }
        func close(_ upper: TextLine, _ lower: TextLine) -> Bool { lower.top - (upper.top + upper.height) < size * 1.5 }
        var first = main, last = main
        while first > 0, sameSize(ordered[first - 1]), close(ordered[first - 1], ordered[first]) { first -= 1 }
        while last + 1 < ordered.count, sameSize(ordered[last + 1]), close(ordered[last], ordered[last + 1]) { last += 1 }
        return (ordered, first, last, size)
    }

    /// A screen's title: its main heading when it clearly stands out from the rest of the text (a page's headline, an
    /// app's title), and the line under it when that reads as a subtitle. Nil for screens of even-sized text (code,
    /// chats, spreadsheets), where no line is "the title".
    public static func screenTitle(in lines: [TextLine]) -> (heading: String, subtitle: String?)? {
        guard lines.count >= 3, let span = headingSpan(in: lines) else { return nil }
        let heights = lines.map(\.height).sorted()
        let median = heights[heights.count / 2]
        guard span.size >= median * 1.4 else { return nil }
        let heading = span.ordered[span.first...span.last].map(\.text).joined(separator: " ")
        var subtitle: String?
        if span.last + 1 < span.ordered.count {
            let below = span.ordered[span.last + 1], above = span.ordered[span.last]
            let gap = below.top - (above.top + above.height)
            if gap < span.size * 3, below.top < 0.5, below.height >= median * 0.95, !below.text.contains(":"),
               below.text.split(separator: " ").count >= 3 {
                subtitle = below.text
            }
        }
        return (heading, subtitle)
    }

    /// A screen title as file-name words: the heading, then the first words of its subtitle.
    public static func slug(_ title: (heading: String, subtitle: String?)) -> String {
        let heading = slug(title.heading, maxWords: 4)
        guard let subtitle = title.subtitle else { return heading }
        let more = slug(subtitle, maxWords: 3).split(separator: "-").filter { !heading.split(separator: "-").contains($0) }
        return Slug.make(([heading] + more.map(String.init)).joined(separator: " "), maxWords: 6, maxLength: 55)
    }

    /// Words that say what a document is, in the languages LabelIt's users write in. Matched near the top of the page.
    static let types = try! NSRegularExpression(
        pattern: #"\b(certificate|diploma|invoice|receipt|contract|agreement|statement|offer letter|payslip|pay slip|resume|curriculum vitae|ticket|boarding pass|itinerary|booking confirmation|order confirmation|quotation|quote|insurance policy|report|faktura|kvitto|avtal|intyg|lönebesked|kontoutdrag|biljett|offert|rechnung|vertrag|bescheinigung|zeugnis|facture|contrat|attestation|factura|contrato|certificado)\b"#,
        options: [.caseInsensitive])

    /// What the page calls itself ("certificate", "faktura"), from its top part.
    public static func type(in lines: [TextLine]) -> String? {
        for line in lines.sorted(by: { $0.top < $1.top }) where line.top < 0.45 {
            let range = NSRange(line.text.startIndex..., in: line.text)
            if let match = types.firstMatch(in: line.text, range: range), let found = Range(match.range, in: line.text) {
                return Slug.make(String(line.text[found]), maxWords: 2, maxLength: 20)
            }
        }
        return nil
    }

    /// Small words a heading reads fine without in a file name.
    static let stopwords: Set<String> = ["a", "an", "the", "of", "for", "with", "and", "to", "in", "on", "at", "by", "from",
                                         "och", "för", "med", "av", "till", "i", "på", "und", "für", "mit", "der", "die",
                                         "das", "et", "de", "la", "le", "les", "du", "y", "el", "los"]

    /// A heading as file-name words, without the small ones.
    public static func slug(_ heading: String, maxWords: Int = 6) -> String {
        let words = heading.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { !stopwords.contains($0.lowercased()) }
        return Slug.make(words.joined(separator: " "), maxWords: maxWords, maxLength: 55)
    }
}

/// Fixes words text recognition misreads in a known way: in many fonts a capital I and a small l are the same shape,
/// so "LabelIt" comes back as "Labellt".
public enum KnownWords {
    public static let words = ["LabelIt", "AirDrop", "EmbeddingGemma", "iPhone", "iPad", "macOS", "iCloud"]

    private static func shape(_ word: some StringProtocol) -> String {
        word.lowercased().replacingOccurrences(of: "i", with: "l")
    }

    private static let byShape: [String: String] = Dictionary(words.map { (shape($0), $0) }, uniquingKeysWith: { a, _ in a })

    public static func correct(_ lines: [TextLine]) -> [TextLine] {
        lines.map { line in
            var text = line.text
            for token in line.text.split(whereSeparator: { !$0.isLetter }) where token.count >= 4 {
                if let known = byShape[shape(token)], known != token { text = text.replacingOccurrences(of: token, with: known) }
            }
            return TextLine(text: text, height: line.height, top: line.top)
        }
    }
}
