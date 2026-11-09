import Foundation

/// Where a file came from. Decides whether and how LabelIt handles it.
public enum Source: String, Codable, Sendable, CaseIterable {
    /// Taken with LabelIt's own capture hotkey.
    case capture
    /// A macOS screenshot (⌘⇧3 / ⌘⇧4 / ⌘⇧5) landing in the screenshot folder.
    case screenshot
    /// Arrived from an iPhone or iPad: AirDrop, Continuity Camera, Image Capture.
    case phone
    /// Any other image or video, picked in Finder with right-click → Rename with LabelIt.
    case finder
}

/// What a file is, as LabelIt understands it.
public enum FileKind: String, Codable, Sendable, CaseIterable {
    case screenshot, error, ui, receipt, document, photo, video, other

    public var tagName: String {
        switch self {
        case .ui: return "UI"
        default: return rawValue.capitalized
        }
    }
}

/// What was on screen when a capture happened. Only knowable at capture time.
public struct CaptureContext: Codable, Sendable, Equatable {
    public var appName: String?
    public var bundleID: String?
    public var windowTitle: String?
    public var url: String?

    public init(appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil, url: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
    }

    public var isEmpty: Bool { appName == nil && windowTitle == nil && url == nil }

    /// Words a window title can have without saying what's in the window.
    static let genericTitleWords: Set<String> = ["desktop", "downloads", "documents", "pictures", "local", "finder", "home",
        "recents", "untitled", "new", "tab", "window", "google", "chrome", "safari", "firefox", "edge", "arc", "brave",
        "the", "and", "for", "with", "from"]

    /// Whether the window's title shows in the picture's text, so the picture is of that window. A macOS screenshot's
    /// app is the one in front when the file lands, which may be another window (Finder, after a click on the Desktop).
    public func isShown(in analysis: ImageAnalysis) -> Bool {
        guard let windowTitle else { return false }
        let titleWords = Slug.make(windowTitle, maxWords: 30, maxLength: 300).split(separator: "-")
            .filter { $0.count >= 3 && !Self.genericTitleWords.contains(String($0)) }
        guard !titleWords.isEmpty else { return false }
        let seen = Set(Slug.make(analysis.fullText, maxWords: 4000, maxLength: 40000).split(separator: "-"))
        return titleWords.contains { seen.contains($0) }
    }
}

/// Facts read from the file itself (EXIF, QuickTime metadata, extended attributes).
public struct MediaMetadata: Sendable, Equatable {
    public var captureDate: Date?
    public var make: String?
    public var model: String?
    public var latitude: Double?
    public var longitude: Double?
    /// Screenshot taken on a Mac (Spotlight attribute) or on an iPhone/iPad (EXIF comment).
    public var isScreenshot: Bool = false
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// A document's own title (PDF metadata), when it has one.
    public var title: String?
    /// The camera's lens, from EXIF: "iPhone 13 Pro front camera 2.71mm f/2.2".
    public var lensModel: String?

    public init() {}

    /// Taken with a phone's front (selfie) camera.
    public var isFrontCamera: Bool {
        lensModel?.localizedCaseInsensitiveContains("front") ?? false
    }

    public var isFromAppleMobileDevice: Bool {
        guard let model else { return false }
        return model.localizedCaseInsensitiveContains("iPhone") || model.localizedCaseInsensitiveContains("iPad")
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }
}

/// One line of recognized text, with its size so headings can be told apart from body text.
public struct TextLine: Sendable, Equatable {
    public var text: String
    /// Height relative to the image (0...1).
    public var height: Double
    /// Distance from the top of the image (0...1).
    public var top: Double

    public init(text: String, height: Double, top: Double) {
        self.text = text
        self.height = height
        self.top = top
    }
}

public struct VisualLabel: Sendable, Equatable {
    public var name: String
    public var confidence: Double

    public init(name: String, confidence: Double) {
        self.name = name
        self.confidence = confidence
    }
}

/// What the image-understanding step saw. Produced by an `ImageUnderstanding` implementation.
public struct ImageAnalysis: Sendable, Equatable {
    public var labels: [VisualLabel] = []
    public var animals: [String] = []
    public var faceCount: Int = 0
    public var lines: [TextLine] = []
    /// What a photo shows, most important first ("dog", "beach", "sunset"), from a `PhotoDescriber`.
    public var descriptions: [String] = []
    /// Subjects that scored nearly as well as the chosen one ("washing-machine" beside "device-label").
    public var alternatives: [String] = []
    /// Whether the reader looks for faces and objects (Apple Vision) rather than only reading text (Tesseract):
    /// no face found means something only then.
    public var detectsObjects = false

    public init(labels: [VisualLabel] = [], animals: [String] = [], faceCount: Int = 0, lines: [TextLine] = [],
                descriptions: [String] = [], detectsObjects: Bool = false) {
        self.labels = labels
        self.animals = animals
        self.faceCount = faceCount
        self.lines = lines
        self.descriptions = descriptions
        self.detectsObjects = detectsObjects
    }

    public var fullText: String { lines.map(\.text).joined(separator: "\n") }
}

/// Everything known about a file before naming it.
public struct FileFacts: Sendable {
    public var url: URL
    public var source: Source
    public var isVideo: Bool
    /// A document (PDF) rather than a picture: named from its title and text.
    public var isDocument: Bool
    public var metadata: MediaMetadata
    public var analysis: ImageAnalysis
    public var context: CaptureContext?
    public var place: String?
    /// When the file was created on this Mac (used when the file carries no capture date).
    public var fileDate: Date

    public init(url: URL, source: Source, isVideo: Bool = false, isDocument: Bool = false,
                metadata: MediaMetadata = MediaMetadata(), analysis: ImageAnalysis = ImageAnalysis(),
                context: CaptureContext? = nil, place: String? = nil, fileDate: Date = Date()) {
        self.url = url
        self.source = source
        self.isVideo = isVideo
        self.isDocument = isDocument
        self.metadata = metadata
        self.analysis = analysis
        self.context = context
        self.place = place
        self.fileDate = fileDate
    }

    /// The best date for the name: when it was taken, not when it was transferred.
    public var bestDate: Date { metadata.captureDate ?? fileDate }

    /// A picture of a screen (named from its text) rather than a camera photo (named from what it shows).
    public var isScreen: Bool { !isDocument && Self.isScreen(source: source, metadata: metadata, url: url) }

    /// The document's title when it says something: not empty, not a file name or ID, not an app's placeholder.
    public var meaningfulTitle: String? { DocumentTitle.meaningful(metadata.title, fileName: url.lastPathComponent) }

    public static func isScreen(source: Source, metadata: MediaMetadata, url: URL) -> Bool {
        switch source {
        case .capture, .screenshot: true
        case .phone: metadata.isScreenshot
        // A PNG no camera made is almost always a screen grab that lost its screenshot marker on the way
        // (Slack, Messages, a browser download).
        case .finder: metadata.isScreenshot || (metadata.make == nil && url.pathExtension.lowercased() == "png")
        }
    }
}

public enum NamerKind: String, Codable, Sendable {
    case appleIntelligence = "Apple Intelligence"
    case rules = "Rules"
}

public struct NamingResult: Sendable, Equatable {
    public var slug: String
    public var kind: FileKind
    public var namer: NamerKind

    public init(slug: String, kind: FileKind, namer: NamerKind) {
        self.slug = slug
        self.kind = kind
        self.namer = namer
    }
}
