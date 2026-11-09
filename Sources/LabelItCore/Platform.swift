import Foundation

// What the pipeline needs from the platform it runs on. `LabelItPlatform` supplies each one: Apple's frameworks on a
// Mac; stb, libheif and Tesseract elsewhere. Everything in LabelItCore is plain Swift and runs anywhere.

/// Pixels to look at: decoded, upright, and already reduced to a sensible size.
public protocol Pixels: Sendable {
    var width: Int { get }
    var height: Int { get }
    /// Packed 8-bit RGB (3 bytes a pixel, rows top to bottom), scaled to exactly `width` × `height`.
    func rgb(width: Int, height: Int) -> [UInt8]?
}

/// Reads files: what they are, their metadata, and their pixels.
public protocol MediaReader: Sendable {
    func isImage(_ url: URL) -> Bool
    func isVideo(_ url: URL) -> Bool
    /// Capture date, device, location, screenshot flag, size.
    func metadata(of url: URL) async -> MediaMetadata
    /// An upright picture no larger than `maxPixelSize` on its long side. For a video, a frame from it.
    func picture(of url: URL, maxPixelSize: Int) async -> (any Pixels)?
    /// A screenshot the system took (macOS marks its own; GNOME and KDE are known by their names).
    func isSystemScreenshot(_ url: URL) -> Bool
    /// A document this platform can read (a PDF on a Mac): renamed only when someone picks it, never by the watchers.
    /// For a document, `picture(of:)` is its first page and `metadata(of:)` has its title and creation date.
    func isDocument(_ url: URL) -> Bool
}

extension MediaReader {
    public func isMedia(_ url: URL) -> Bool { isImage(url) || isVideo(url) }
    public func isDocument(_ url: URL) -> Bool { false }
}

/// Document titles that are worth using in a name.
public enum DocumentTitle {
    /// What apps put in the title when the person didn't write one.
    static let placeholder = try! NSRegularExpression(
        pattern: #"^(untitled|document\d*|doc\d*|title|new document|microsoft (word|powerpoint|excel)\b.*|.*\.(docx?|pptx?|xlsx?|pdf|pages|key|numbers|txt|rtf|odt|html?))$"#,
        options: [.caseInsensitive])

    public static func meaningful(_ title: String?, fileName: String) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), title.count >= 3 else { return nil }
        let range = NSRange(title.startIndex..., in: title)
        if placeholder.firstMatch(in: title, range: range) != nil { return nil }
        if title == (fileName as NSString).deletingPathExtension { return nil }
        // A title has at least one real word: three or more letters and no digits. IDs ("UC-c796945e-d9b7-…") and
        // dates don't.
        let words = title.split { !$0.isLetter && !$0.isNumber }
        guard words.contains(where: { $0.count >= 3 && $0.allSatisfy(\.isLetter) }) else { return nil }
        return title
    }
}

/// Looks at a picture and reports what's in it: text with positions, and labels where the platform can tell.
public protocol ImageUnderstanding: Sendable {
    func analyze(_ picture: any Pixels, readText: Bool) async -> ImageAnalysis
}

/// Describes what a photo shows in a few words, most important first: ["dog", "beach", "sunset"].
/// Used for camera photos and videos only; screenshots are named from their text.
/// Returns [] when it has nothing confident to say (or isn't available).
public protocol PhotoDescriber: Sendable {
    func describe(_ picture: any Pixels) async -> [String]
}

/// Turns coordinates into a city name.
public protocol PlaceLookup: Sendable {
    func place(latitude: Double, longitude: Double) async -> String?
}

/// File types by extension, for platforms without a type system to ask (and for pairing Live Photos).
public enum MediaTypes {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "hif", "webp", "gif",
                                                      "tif", "tiff", "bmp", "avif"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm"]

    public static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }
    public static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }
}

/// Decoded pixels in memory, as packed RGB. What non-Apple platforms decode into.
public struct RGBPicture: Pixels {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height * 3 else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public func rgb(width newWidth: Int, height newHeight: Int) -> [UInt8]? {
        guard newWidth > 0, newHeight > 0 else { return nil }
        if newWidth == width && newHeight == height { return pixels }
        return newWidth <= width && newHeight <= height
            ? Self.shrink(pixels, width, height, newWidth, newHeight)
            : Self.bilinear(pixels, width, height, newWidth, newHeight)
    }

    /// Scaled so the long side is at most `maxPixelSize` (never enlarged).
    public func fitting(_ maxPixelSize: Int) -> RGBPicture {
        let longSide = max(width, height)
        guard longSide > maxPixelSize, maxPixelSize > 0 else { return self }
        let scale = Double(maxPixelSize) / Double(longSide)
        let newWidth = max(1, Int((Double(width) * scale).rounded()))
        let newHeight = max(1, Int((Double(height) * scale).rounded()))
        return RGBPicture(width: newWidth, height: newHeight, pixels: rgb(width: newWidth, height: newHeight)!)!
    }

    /// EXIF orientation (1–8) applied, so the picture is upright.
    public func oriented(_ orientation: Int) -> RGBPicture {
        guard (2...8).contains(orientation) else { return self }
        let swaps = orientation >= 5
        let newWidth = swaps ? height : width, newHeight = swaps ? width : height
        var out = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                // Where the pixel at (x, y) of the upright picture comes from in the stored one.
                let (sx, sy): (Int, Int) = switch orientation {
                case 2: (width - 1 - x, y)
                case 3: (width - 1 - x, height - 1 - y)
                case 4: (x, height - 1 - y)
                case 5: (y, x)
                case 6: (y, height - 1 - x)
                case 7: (width - 1 - y, height - 1 - x)
                default: (width - 1 - y, x)   // 8
                }
                let source = (sy * width + sx) * 3, target = (y * newWidth + x) * 3
                out[target] = pixels[source]
                out[target + 1] = pixels[source + 1]
                out[target + 2] = pixels[source + 2]
            }
        }
        return RGBPicture(width: newWidth, height: newHeight, pixels: out)!
    }

    /// Area averaging: each output pixel is the mean of the source pixels it covers. Sharp and alias-free when shrinking.
    static func shrink(_ src: [UInt8], _ w: Int, _ h: Int, _ nw: Int, _ nh: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: nw * nh * 3)
        let xScale = Double(w) / Double(nw), yScale = Double(h) / Double(nh)
        src.withUnsafeBufferPointer { s in
            for y in 0..<nh {
                let y0 = Int(Double(y) * yScale), y1 = max(y0 + 1, min(h, Int((Double(y + 1) * yScale).rounded(.up))))
                for x in 0..<nw {
                    let x0 = Int(Double(x) * xScale), x1 = max(x0 + 1, min(w, Int((Double(x + 1) * xScale).rounded(.up))))
                    var r = 0, g = 0, b = 0
                    for sy in y0..<y1 {
                        var i = (sy * w + x0) * 3
                        for _ in x0..<x1 {
                            r += Int(s[i]); g += Int(s[i + 1]); b += Int(s[i + 2])
                            i += 3
                        }
                    }
                    let count = (y1 - y0) * (x1 - x0), o = (y * nw + x) * 3
                    out[o] = UInt8(r / count); out[o + 1] = UInt8(g / count); out[o + 2] = UInt8(b / count)
                }
            }
        }
        return out
    }

    static func bilinear(_ src: [UInt8], _ w: Int, _ h: Int, _ nw: Int, _ nh: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: nw * nh * 3)
        for y in 0..<nh {
            let fy = max(0, (Double(y) + 0.5) * Double(h) / Double(nh) - 0.5)
            let y0 = min(Int(fy), h - 1), y1 = min(y0 + 1, h - 1), wy = fy - Double(y0)
            for x in 0..<nw {
                let fx = max(0, (Double(x) + 0.5) * Double(w) / Double(nw) - 0.5)
                let x0 = min(Int(fx), w - 1), x1 = min(x0 + 1, w - 1), wx = fx - Double(x0)
                for c in 0..<3 {
                    let top = Double(src[(y0 * w + x0) * 3 + c]) * (1 - wx) + Double(src[(y0 * w + x1) * 3 + c]) * wx
                    let bottom = Double(src[(y1 * w + x0) * 3 + c]) * (1 - wx) + Double(src[(y1 * w + x1) * 3 + c]) * wx
                    out[(y * nw + x) * 3 + c] = UInt8((top * (1 - wy) + bottom * wy).rounded())
                }
            }
        }
        return out
    }
}
