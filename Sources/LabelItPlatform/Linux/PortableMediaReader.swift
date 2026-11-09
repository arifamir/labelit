#if !os(macOS)
import CHeif
import CStb
import Foundation
import LabelItCore

/// Files without Apple's frameworks: metadata from `MetadataParser`, pixels from libheif (HEIC, HEIF, AVIF) and stb
/// (JPEG, PNG, GIF, BMP). Video frames need FFmpeg, which comes with the desktop app; until then a video is named
/// from its metadata, or follows its Live Photo image.
public struct PortableMediaReader: MediaReader {
    public init() {}

    public func isImage(_ url: URL) -> Bool { MediaTypes.isImage(url) }
    public func isVideo(_ url: URL) -> Bool { MediaTypes.isVideo(url) }

    public func metadata(of url: URL) async -> MediaMetadata {
        var metadata = MetadataParser.read(url).metadata
        if isSystemScreenshot(url) { metadata.isScreenshot = true }
        return metadata
    }

    public func picture(of url: URL, maxPixelSize: Int) async -> (any Pixels)? {
        guard isImage(url) else { return nil }
        let ext = url.pathExtension.lowercased()
        if ["heic", "heif", "hif", "avif"].contains(ext) {
            // libheif applies the file's own rotation and mirroring.
            return Self.decodeHEIF(url)?.fitting(maxPixelSize)
        }
        guard let decoded = Self.decodeStb(url) else { return nil }
        return decoded.oriented(MetadataParser.read(url).orientation).fitting(maxPixelSize)
    }

    /// GNOME, KDE and other tools don't mark screenshots, but name them consistently.
    public func isSystemScreenshot(_ url: URL) -> Bool {
        isImage(url) && NamePatterns.looksLikeScreenshotToolName(url.lastPathComponent)
    }

    // MARK: Decoding

    static func decodeStb(_ url: URL) -> RGBPicture? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty, data.count < Int(Int32.max) else {
            return nil
        }
        var width: Int32 = 0, height: Int32 = 0
        let pixels: UnsafeMutablePointer<UInt8>? = data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return labelit_stb_load_rgb(base, Int32(buffer.count), &width, &height)
        }
        guard let pixels else { return nil }
        defer { labelit_stb_free(pixels) }
        let count = Int(width) * Int(height) * 3
        return RGBPicture(width: Int(width), height: Int(height), pixels: Array(UnsafeBufferPointer(start: pixels, count: count)))
    }

    private static let heifReady: Void = { _ = heif_init(nil) }()

    static func decodeHEIF(_ url: URL) -> RGBPicture? {
        _ = heifReady
        guard let context = heif_context_alloc() else { return nil }
        defer { heif_context_free(context) }
        guard heif_context_read_from_file(context, url.path, nil).code == heif_error_Ok else { return nil }
        var handle: OpaquePointer?
        guard heif_context_get_primary_image_handle(context, &handle).code == heif_error_Ok, let handle else { return nil }
        defer { heif_image_handle_release(handle) }
        var image: OpaquePointer?
        guard heif_decode_image(handle, &image, heif_colorspace_RGB, heif_chroma_interleaved_RGB, nil).code == heif_error_Ok,
              let image else { return nil }
        defer { heif_image_release(image) }
        var stride: Int32 = 0
        guard let plane = heif_image_get_plane_readonly(image, heif_channel_interleaved, &stride) else { return nil }
        let width = Int(heif_image_get_width(image, heif_channel_interleaved))
        let height = Int(heif_image_get_height(image, heif_channel_interleaved))
        guard width > 0, height > 0 else { return nil }
        // Rows may be padded: copy each row's pixels only.
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        pixels.withUnsafeMutableBufferPointer { out in
            for row in 0..<height {
                (out.baseAddress! + row * width * 3).update(from: plane + row * Int(stride), count: width * 3)
            }
        }
        return RGBPicture(width: width, height: height, pixels: pixels)
    }
}
#endif
