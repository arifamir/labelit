import Foundation
import LabelItCore

/// The pieces this platform provides to the pipeline.
///
/// | | macOS | Linux |
/// |---|---|---|
/// | Files and metadata | ImageIO, AVFoundation | stb, libheif, `MetadataParser` |
/// | Text and labels | Vision | Tesseract (text only) |
/// | Names | Apple Intelligence, else rules | rules |
/// | Places | Apple's location service | — |
/// | Folder events | FSEvents | inotify |
public enum NativePlatform {
    public static let name: String = {
        #if os(macOS)
        "macOS"
        #elseif os(Linux)
        "Linux"
        #elseif os(Windows)
        "Windows"
        #else
        "unknown"
        #endif
    }()

    public static func reader() -> any MediaReader {
        #if os(macOS)
        AppleMediaReader()
        #else
        PortableMediaReader()
        #endif
    }

    public static func understanding() -> any ImageUnderstanding {
        #if os(macOS)
        VisionUnderstanding()
        #else
        TesseractUnderstanding()
        #endif
    }

    public static func namer() -> any Namer {
        #if canImport(FoundationModels)
        AppleIntelligenceNamer()
        #else
        RuleNamer()
        #endif
    }

    /// Nil where there's no place lookup.
    public static func places() -> (any PlaceLookup)? {
        #if canImport(MapKit)
        PlaceResolver()
        #else
        nil
        #endif
    }

    /// What writes the names right now: "Apple Intelligence" or "Built-in rules".
    public static var namerDescription: String {
        #if canImport(FoundationModels)
        AppleIntelligenceNamer.isAvailable ? "Apple Intelligence" : "Built-in rules"
        #else
        "Built-in rules"
        #endif
    }

    /// Why the better namer isn't in use, when there is one this platform could use.
    public static var namerHint: String? {
        #if canImport(FoundationModels)
        AppleIntelligenceNamer.unavailableReason
        #else
        nil
        #endif
    }

    /// What reads text in pictures here, and whether it's ready (Tesseract may not be installed).
    public static var textReaderStatus: String {
        #if os(macOS)
        "Vision"
        #else
        TesseractUnderstanding.status
        #endif
    }
}

extension Labeler {
    /// A labeler built from this platform's pieces.
    public static func native(describer: (any PhotoDescriber)? = nil, log: RenameLog,
                              settings: LabelerSettings = LabelerSettings()) -> Labeler {
        Labeler(reader: NativePlatform.reader(), understanding: NativePlatform.understanding(), describer: describer,
                namer: NativePlatform.namer(), log: log, places: NativePlatform.places(), settings: settings)
    }
}
