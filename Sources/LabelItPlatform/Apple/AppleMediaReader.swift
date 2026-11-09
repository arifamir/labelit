#if os(macOS)
import AVFoundation
import CoreGraphics
import Foundation
import AppKit
import ImageIO
import LabelItCore
import PDFKit
import UniformTypeIdentifiers

/// Files through Apple's frameworks: types from UTType, metadata from ImageIO and AVFoundation, pixels as CGImages.
public struct AppleMediaReader: MediaReader {
    public init() {}

    public func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    public func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    public func isDocument(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) ?? false
    }

    public func metadata(of url: URL) async -> MediaMetadata {
        if isDocument(url) { return Self.readPDF(url) }
        var metadata = isVideo(url) ? await Self.readVideo(url) : Self.readImage(url)
        if FileMarkers.isMacScreenshot(url) { metadata.isScreenshot = true }
        return metadata
    }

    public func picture(of url: URL, maxPixelSize: Int) async -> (any Pixels)? {
        if isDocument(url) { return Self.firstPage(of: url, maxPixelSize: maxPixelSize).map(CGPicture.init) }
        let image = isVideo(url) ? await Self.videoFrame(at: url, maxPixelSize: maxPixelSize)
                                 : Self.image(at: url, maxPixelSize: maxPixelSize)
        return image.map(CGPicture.init)
    }

    public func isSystemScreenshot(_ url: URL) -> Bool { FileMarkers.isMacScreenshot(url) }

    // MARK: Images

    static func readImage(_ url: URL) -> MediaMetadata {
        var metadata = MediaMetadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return metadata
        }
        metadata.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        metadata.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        metadata.make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        metadata.model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            metadata.captureDate = MetadataParser.parseExifDate(original, offset: offset)
        }
        // iOS writes "Screenshot" into the EXIF user comment of screenshots.
        if let comment = exif[kCGImagePropertyExifUserComment] as? String,
           comment.localizedCaseInsensitiveContains("screenshot") {
            metadata.isScreenshot = true
        }
        // PNG screenshots from macOS carry this description.
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           let description = png[kCGImagePropertyPNGDescription] as? String,
           description.localizedCaseInsensitiveContains("screenshot") {
            metadata.isScreenshot = true
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { lon = -lon }
            if !(lat == 0 && lon == 0) {
                metadata.latitude = lat
                metadata.longitude = lon
            }
        }
        return metadata
    }

    static func image(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: PDFs

    /// The title and creation date a PDF records about itself.
    static func readPDF(_ url: URL) -> MediaMetadata {
        var metadata = MediaMetadata()
        guard let document = PDFDocument(url: url), !document.isLocked else { return metadata }
        let attributes = document.documentAttributes ?? [:]
        metadata.title = attributes[PDFDocumentAttribute.titleAttribute] as? String
        metadata.captureDate = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            metadata.pixelWidth = Int(box.width)
            metadata.pixelHeight = Int(box.height)
        }
        return metadata
    }

    /// The first page, upright, on white, `maxPixelSize` on its long side (small pages are enlarged: text needs pixels).
    static func firstPage(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let document = PDFDocument(url: url), !document.isLocked, let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let size = page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = CGFloat(maxPixelSize) / max(size.width, size.height)
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        // PDFKit's thumbnail applies the page's rotation; drawn into a bitmap of exactly this size.
        let thumbnail = page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        thumbnail.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    // MARK: Videos

    static func readVideo(_ url: URL) async -> MediaMetadata {
        var metadata = MediaMetadata()
        let asset = AVURLAsset(url: url)
        if let date = try? await asset.load(.creationDate), let value = try? await date.load(.dateValue) {
            metadata.captureDate = value
        }
        let items = (try? await asset.load(.metadata)) ?? []
        for item in items {
            guard let key = item.identifier else { continue }
            switch key {
            case .quickTimeMetadataModel, .commonIdentifierModel:
                metadata.model = try? await item.load(.stringValue)
            case .quickTimeMetadataMake, .commonIdentifierMake:
                metadata.make = try? await item.load(.stringValue)
            case .quickTimeMetadataLocationISO6709, .commonIdentifierLocation:
                if let value = try? await item.load(.stringValue), let (lat, lon) = MetadataParser.parseISO6709(value) {
                    metadata.latitude = lat
                    metadata.longitude = lon
                }
            default:
                break
            }
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            metadata.pixelWidth = Int(abs(size.width))
            metadata.pixelHeight = Int(abs(size.height))
        }
        return metadata
    }

    static func videoFrame(at url: URL, maxPixelSize: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        // A frame a little way in avoids black first frames.
        let seconds = duration > 2 ? min(duration / 3, 5) : 0
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}

/// A CGImage as `Pixels`. Resizing draws through Core Graphics, as the rest of macOS does.
public struct CGPicture: Pixels, @unchecked Sendable {   // CGImage is immutable
    public let image: CGImage

    public init(_ image: CGImage) { self.image = image }

    public var width: Int { image.width }
    public var height: Int { image.height }

    public func rgb(width: Int, height: Int) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return rgb
    }

    /// The CGImage behind a picture, making one for pictures decoded some other way.
    static func cgImage(from picture: any Pixels) -> CGImage? {
        if let picture = picture as? CGPicture { return picture.image }
        guard let rgb = picture.rgb(width: picture.width, height: picture.height),
              let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
        return CGImage(width: picture.width, height: picture.height, bitsPerComponent: 8, bitsPerPixel: 24,
                       bytesPerRow: picture.width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
#endif
