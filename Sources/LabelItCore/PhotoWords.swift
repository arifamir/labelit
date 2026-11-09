import Foundation

/// What the picture must show, by the image reader (Apple Vision), before a describer's match can name it.
public enum Evidence: Sendable, Hashable {
    /// A face, which is the subject itself: a portrait, a selfie. Seeing one confirms the match.
    case face
    /// Someone in the picture (a haircut, a family, a baby): no face rules it out, but a face doesn't confirm what's
    /// happening, so the match still needs its full score.
    case someone
    /// One of these classifier labels, or an animal the animal detector found ("dog", "snow", "sunset_sunrise").
    case seen([String])
}

/// One of a photo describer's matches: a phrase's short name and how far its score stands out from all phrases'
/// (in standard deviations).
public struct PhotoMatch: Sendable, Equatable {
    public enum Group: String, Sendable, CaseIterable {
        case subject, setting, light
    }

    public let slug: String
    public let group: Group
    public let zScore: Double
    public let needs: Evidence?

    public init(slug: String, group: Group, zScore: Double, needs: Evidence? = nil) {
        self.slug = slug
        self.group = group
        self.zScore = zScore
        self.needs = needs
    }
}

/// Picks a photo's words from a describer's matches, checked against what the image reader saw.
///
/// A match whose evidence is missing is dropped ("portrait" with no face). A match the reader backs up counts from a
/// lower score: two independent readings agree. And a photo from the front camera with a face in it is a selfie,
/// whatever the describer says.
public enum PhotoWords {
    /// The score a match needs on its own. Measured on 28 phone photos (2026-11-09): true subjects scored z 3.4–5.6,
    /// wrong guesses up to 3.1.
    public static let thresholds: [PhotoMatch.Group: Double] = [.subject: 3.3, .setting: 3.0, .light: 3.0]
    /// How much lower a match the image reader confirms may score.
    public static let confirmedDiscount = 0.5
    /// Only a group's best few matches are considered: further down, a confirmed match is a long shot.
    static let considered = 3

    public static func choose(_ matches: [PhotoMatch], analysis: ImageAnalysis, metadata: MediaMetadata) -> [String] {
        var chosen: [String] = []
        let selfie = metadata.isFrontCamera && analysis.faceCount > 0
        if selfie { chosen.append("selfie") }
        for group in PhotoMatch.Group.allCases {
            let ranked = matches.filter { $0.group == group }.sorted { $0.zScore > $1.zScore }
            for match in ranked.prefix(considered) {
                if selfie && ["selfie", "portrait"].contains(match.slug) { continue }
                let backed = isBacked(match.needs, by: analysis)
                if backed == false { continue }
                let needed = thresholds[group, default: 3] - (backed == true ? confirmedDiscount : 0)
                guard match.zScore >= needed else { continue }
                if !isRedundant(match.slug, after: chosen) { chosen.append(match.slug) }
                break
            }
        }
        return chosen
    }

    /// Subjects that scored within `alternativeRange` of the chosen one and that the reader doesn't rule out: what the
    /// photo could also be called. A language model picks among them with the photo's text in view.
    public static func alternatives(_ matches: [PhotoMatch], chosen: [String], analysis: ImageAnalysis) -> [String] {
        let subjects = matches.filter { $0.group == .subject }.sorted { $0.zScore > $1.zScore }
        guard let best = subjects.first(where: { chosen.contains($0.slug) }) else { return [] }
        return subjects
            .filter { !chosen.contains($0.slug) && isBacked($0.needs, by: analysis) != false }
            .filter { best.zScore - $0.zScore <= alternativeRange && !isRedundant($0.slug, after: chosen) }
            .prefix(2)
            .map(\.slug)
    }

    static let alternativeRange = 0.6

    /// true: the reader saw it; false: it didn't (or saw nobody, for someone); nil: nothing that confirms it, or a
    /// reader that doesn't look for faces and objects (Tesseract on Linux reads text only): the match stands on its
    /// score.
    public static func isBacked(_ needs: Evidence?, by analysis: ImageAnalysis) -> Bool? {
        guard let needs, analysis.detectsObjects else { return nil }
        switch needs {
        case .face:
            return analysis.faceCount > 0
        case .someone:
            return analysis.faceCount > 0 ? nil : false
        case .seen(let names):
            return names.contains { name in
                analysis.animals.contains(name) || analysis.labels.contains { $0.name == name }
            }
        }
    }

    /// Subjects that are paper or a page: a photo of one is a document, named from its text.
    public static let paper: Set<String> = [
        "document", "letter", "form", "textbook", "receipt", "handwritten-note", "whiteboard", "slides", "sign", "menu",
        "ticket", "id-card", "map", "meme", "book",
    ]

    /// "garden" after "garden", "snowy" after "snow": the same thing said twice.
    public static func isRedundant(_ slug: String, after chosen: [String]) -> Bool {
        let earlier = chosen.flatMap { $0.split(separator: "-").map(String.init) }
        return slug.split(separator: "-").allSatisfy { word in
            earlier.contains { $0.hasPrefix(word) || word.hasPrefix($0) }
        }
    }
}
