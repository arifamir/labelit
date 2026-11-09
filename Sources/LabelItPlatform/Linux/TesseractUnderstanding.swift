#if !os(macOS)
import CTesseract
import Foundation
import LabelItCore

/// Text in pictures with Tesseract: each line with its position, as Vision reports it on a Mac. Text only: labels for
/// photos come from EmbeddingGemma 2.
///
/// Languages: English plus the system's language when its data is installed (`tesseract-ocr-swe` for Swedish…), or
/// exactly `LABELIT_OCR_LANGUAGES` (Tesseract's codes joined with "+", e.g. "eng+deu").
public struct TesseractUnderstanding: ImageUnderstanding {
    public init() {}

    /// Lines Tesseract is less sure of than this (0–100) are left out. On camera photos it "reads" texture as words at
    /// 30–60; real text scores above that.
    static let minimumConfidence: Float = 65

    static let languages: String = {
        if let chosen = ProcessInfo.processInfo.environment["LABELIT_OCR_LANGUAGES"], !chosen.isEmpty { return chosen }
        let environment = ProcessInfo.processInfo.environment
        let locale = environment["LC_ALL"] ?? environment["LC_MESSAGES"] ?? environment["LANG"] ?? ""
        let code = String(locale.prefix(2)).lowercased()
        guard let system = systemLanguages[code], system != "eng" else { return "eng" }
        // Only with its data installed; otherwise Tesseract wouldn't start at all.
        guard let api = TessBaseAPICreate() else { return "eng" }
        defer { TessBaseAPIDelete(api) }
        let both = "eng+\(system)"
        guard TessBaseAPIInit3(api, nil, both) == 0 else { return "eng" }
        TessBaseAPIEnd(api)
        return both
    }()

    /// ISO 639-1 (from the locale) to Tesseract's language data names.
    static let systemLanguages: [String: String] = [
        "sv": "swe", "de": "deu", "fr": "fra", "es": "spa", "it": "ita", "nl": "nld", "pt": "por", "pl": "pol",
        "da": "dan", "nb": "nor", "nn": "nor", "no": "nor", "fi": "fin", "cs": "ces", "hu": "hun", "ro": "ron",
        "ru": "rus", "uk": "ukr", "el": "ell", "tr": "tur", "ar": "ara", "ur": "urd", "fa": "fas", "he": "heb",
        "hi": "hin", "bn": "ben", "zh": "chi_sim", "ja": "jpn", "ko": "kor", "vi": "vie", "th": "tha", "id": "ind",
    ]

    /// "Tesseract 5.3.4 (eng)", or what's missing.
    public static var status: String {
        let version = String(cString: TessVersion())
        guard let api = TessBaseAPICreate() else { return "Tesseract \(version): can't start" }
        defer { TessBaseAPIDelete(api) }
        guard TessBaseAPIInit3(api, nil, languages) == 0 else {
            return "Tesseract \(version): no language data for \(languages) (install tesseract-ocr-\(languages.split(separator: "+").first ?? "eng"))"
        }
        TessBaseAPIEnd(api)
        return "Tesseract \(version) (\(languages))"
    }

    public func analyze(_ picture: any Pixels, readText: Bool) async -> ImageAnalysis {
        guard readText else { return ImageAnalysis() }
        return ImageAnalysis(lines: Self.recognize(picture))
    }

    static func recognize(_ picture: any Pixels) -> [TextLine] {
        let width = picture.width, height = picture.height
        guard let rgb = picture.rgb(width: width, height: height), let api = TessBaseAPICreate() else { return [] }
        defer { TessBaseAPIDelete(api) }
        guard TessBaseAPIInit3(api, nil, languages) == 0 else { return [] }
        defer { TessBaseAPIEnd(api) }
        TessBaseAPISetPageSegMode(api, PSM_AUTO)
        // Quiet: Tesseract otherwise reports its resolution guesses on stderr for every picture.
        TessBaseAPISetVariable(api, "debug_file", "/dev/null")
        rgb.withUnsafeBufferPointer { buffer in
            TessBaseAPISetImage(api, buffer.baseAddress, Int32(width), Int32(height), 3, Int32(width * 3))
        }
        guard TessBaseAPIRecognize(api, nil) == 0, let results = TessBaseAPIGetIterator(api) else { return [] }
        defer { TessResultIteratorDelete(results) }
        let page = TessResultIteratorGetPageIterator(results)

        var lines: [TextLine] = []
        repeat {
            guard let cText = TessResultIteratorGetUTF8Text(results, RIL_TEXTLINE) else { continue }
            let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
            TessDeleteText(cText)
            let confidence = TessResultIteratorConfidence(results, RIL_TEXTLINE)
            var left: Int32 = 0, top: Int32 = 0, right: Int32 = 0, bottom: Int32 = 0
            guard !text.isEmpty, confidence >= minimumConfidence,
                  TessPageIteratorBoundingBox(page, RIL_TEXTLINE, &left, &top, &right, &bottom) != 0 else { continue }
            lines.append(TextLine(text: text, height: Double(bottom - top) / Double(height), top: Double(top) / Double(height)))
        } while TessResultIteratorNext(results, RIL_TEXTLINE) != 0
        return lines.sorted { $0.top < $1.top }
    }
}
#endif
