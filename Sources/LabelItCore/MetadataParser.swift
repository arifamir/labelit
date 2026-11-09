import Foundation

/// Reads capture date, device, location, orientation and screenshot markers straight from the file, in plain Swift:
/// EXIF in JPEG, HEIC and PNG; PNG text and XMP; QuickTime metadata in MOV and MP4. Reads only the parts it needs.
///
/// Used where the system has no metadata reader (Linux, Windows). On a Mac, ImageIO and AVFoundation do the same job,
/// and the tests compare the two.
public enum MetadataParser {
    public struct Result: Sendable, Equatable {
        public var metadata = MediaMetadata()
        /// EXIF orientation, 1 (upright) to 8.
        public var orientation = 1
    }

    public static func read(_ url: URL) -> Result {
        guard let file = FileReader(url) else { return Result() }
        defer { file.close() }
        guard let head = file.read(at: 0, count: 16), head.count >= 12 else { return Result() }
        if head.starts(with: [0xFF, 0xD8]) { return jpeg(file) }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return png(file) }
        if Array(head[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            if ["heic", "heix", "heim", "heis", "hevc", "mif1", "msf1", "avif"].contains(brand) { return heif(file) }
            return quickTime(file)
        }
        if ["moov", "mdat", "wide", "free", "skip"].contains(String(decoding: head[4..<8], as: UTF8.self)) {
            return quickTime(file)
        }
        return Result()
    }

    // MARK: JPEG

    static func jpeg(_ file: FileReader) -> Result {
        var offset: UInt64 = 2
        var result = Result()
        while let marker = file.read(at: offset, count: 4), marker.count == 4, marker[0] == 0xFF {
            let type = marker[1]
            if type == 0xDA || type == 0xD9 { break }   // image data starts: no more metadata
            let length = UInt64(marker[2]) << 8 | UInt64(marker[3])
            if type == 0xE1, length > 8, let body = file.read(at: offset + 4, count: Int(length) - 2),
               body.starts(with: Array("Exif\0\0".utf8)) {
                apply(tiff: Array(body.dropFirst(6)), to: &result)
            } else if type == 0xC0 || type == 0xC2, let frame = file.read(at: offset + 5, count: 4), frame.count == 4 {
                result.metadata.pixelHeight = Int(frame[0]) << 8 | Int(frame[1])
                result.metadata.pixelWidth = Int(frame[2]) << 8 | Int(frame[3])
            }
            offset += 2 + length
        }
        return result
    }

    // MARK: PNG

    static func png(_ file: FileReader) -> Result {
        var result = Result()
        var offset: UInt64 = 8
        while let header = file.read(at: offset, count: 8), header.count == 8 {
            let length = UInt64(readBE32(header, 0))
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if type == "IEND" { break }
            let wanted = ["IHDR", "eXIf", "tEXt", "iTXt"].contains(type) && length < 4 << 20
            if wanted, let body = file.read(at: offset + 8, count: Int(length)) {
                switch type {
                case "IHDR" where body.count >= 8:
                    result.metadata.pixelWidth = Int(readBE32(body, 0))
                    result.metadata.pixelHeight = Int(readBE32(body, 4))
                case "eXIf":
                    apply(tiff: body, to: &result)
                default:
                    pngText(type: type, body, into: &result)
                }
            }
            offset += 12 + length
        }
        return result
    }

    /// macOS screenshots say "Screenshot" in their description; iOS ones put it in the XMP user comment.
    static func pngText(type: String, _ body: [UInt8], into result: inout Result) {
        guard let nul = body.firstIndex(of: 0) else { return }
        let keyword = String(decoding: body[..<nul], as: UTF8.self)
        var text: String
        if type == "tEXt" {
            text = String(decoding: body[(nul + 1)...], as: UTF8.self)
        } else {
            // iTXt: keyword \0 compressed? method language \0 translated-keyword \0 text
            guard body.count > nul + 2, body[nul + 1] == 0 else { return }   // compressed text: not needed here
            var rest = body[(nul + 3)...]
            for _ in 0..<2 {
                guard let end = rest.firstIndex(of: 0) else { return }
                rest = rest[(end + 1)...]
            }
            text = String(decoding: rest, as: UTF8.self)
        }
        if keyword == "Description", text.localizedCaseInsensitiveContains("screenshot") {
            result.metadata.isScreenshot = true
        }
        if keyword == "XML:com.adobe.xmp" {
            text = text.replacingOccurrences(of: "\n", with: " ")
            if text.range(of: #"UserComment.{0,300}?Screenshot"#, options: [.regularExpression, .caseInsensitive]) != nil {
                result.metadata.isScreenshot = true
            }
            if result.metadata.captureDate == nil,
               let match = text.range(of: #"(?<=DateCreated>)[^<]+|(?<=DateCreated=")[^"]+"#, options: .regularExpression) {
                result.metadata.captureDate = parseISODate(String(text[match]))
            }
        }
    }

    // MARK: HEIF (HEIC from an iPhone)

    /// EXIF in a HEIF file is an item: `meta` lists it in `iinf` (type "Exif") and says where it is in `iloc`.
    static func heif(_ file: FileReader) -> Result {
        var result = Result()
        guard let meta = file.findBox("meta", in: 0..<file.size), let content = file.read(at: meta.start + 4, count: Int(min(meta.length - 4, 1 << 20))) else {
            return result
        }
        // `meta` is a full box: 4 bytes of version and flags, then boxes.
        let boxes = Box.list(content, from: 0)
        var exifID: UInt32?
        var orientation = 1
        if let iinf = boxes.first(where: { $0.type == "iinf" }) {
            let version = byte(content, iinf.body)
            var cursor = iinf.body + 4
            let count = version == 0 ? Int(readBE16(content, cursor)) : Int(readBE32(content, cursor))
            cursor += version == 0 ? 2 : 4
            for entry in Box.list(content, from: cursor, until: iinf.end).prefix(count) where entry.type == "infe" {
                let infeVersion = byte(content, entry.body)
                guard infeVersion >= 2 else { continue }
                let idSize = infeVersion == 2 ? 2 : 4
                let idAt = entry.body + 4
                let id = idSize == 2 ? UInt32(readBE16(content, idAt)) : readBE32(content, idAt)
                let typeAt = idAt + idSize + 2
                if typeAt + 4 <= min(entry.end, content.count), String(decoding: content[typeAt..<typeAt + 4], as: UTF8.self) == "Exif" {
                    exifID = id
                }
            }
        }
        // irot in the item properties: rotation of the primary image (counter-clockwise, in 90° steps).
        if let iprp = boxes.first(where: { $0.type == "iprp" }),
           let ipco = Box.list(content, from: iprp.body, until: iprp.end).first(where: { $0.type == "ipco" }),
           let irot = Box.list(content, from: ipco.body, until: ipco.end).first(where: { $0.type == "irot" }) {
            orientation = [1, 8, 3, 6][Int(byte(content, irot.body) & 3)]
        }
        if let exifID, let iloc = boxes.first(where: { $0.type == "iloc" }),
           let (offset, length) = ilocExtent(content, iloc, itemID: exifID),
           let blob = file.read(at: offset, count: Int(min(length, 1 << 20))), blob.count > 4 {
            // The blob starts with the offset of the TIFF header within it.
            let skip = Int(readBE32(blob, 0)) + 4
            if skip < blob.count { apply(tiff: Array(blob[skip...]), to: &result) }
        }
        // HEIF players rotate by irot and ignore EXIF orientation.
        result.orientation = orientation
        return result
    }

    static func ilocExtent(_ data: [UInt8], _ box: Box, itemID: UInt32) -> (UInt64, UInt64)? {
        let version = byte(data, box.body)
        var cursor = box.body + 4
        let offsetSize = Int(byte(data, cursor) >> 4), lengthSize = Int(byte(data, cursor) & 15)
        let baseOffsetSize = Int(byte(data, cursor + 1) >> 4), indexSize = version >= 1 ? Int(byte(data, cursor + 1) & 15) : 0
        cursor += 2
        let count = version < 2 ? Int(readBE16(data, cursor)) : Int(readBE32(data, cursor))
        cursor += version < 2 ? 2 : 4
        func number(_ size: Int) -> UInt64 {
            defer { cursor += size }
            switch size {
            case 4: return UInt64(readBE32(data, cursor))
            case 8: return UInt64(readBE32(data, cursor)) << 32 | UInt64(readBE32(data, cursor + 4))
            case 2: return UInt64(readBE16(data, cursor))
            default: return 0
            }
        }
        for _ in 0..<count {
            guard cursor + 16 <= box.end else { return nil }
            let id = version < 2 ? UInt32(number(2)) : UInt32(number(4))
            if version >= 1 { cursor += 2 }   // construction method
            cursor += 2                       // data reference index
            let base = number(baseOffsetSize)
            let extents = Int(number(2))
            var first: (UInt64, UInt64)?
            for _ in 0..<extents {
                if indexSize > 0 { _ = number(indexSize) }
                let offset = number(offsetSize), length = number(lengthSize)
                if first == nil { first = (base + offset, length) }
            }
            if id == itemID { return first }
        }
        return nil
    }

    // MARK: QuickTime (MOV, MP4)

    static func quickTime(_ file: FileReader) -> Result {
        var result = Result()
        guard let moov = file.findBox("moov", in: 0..<file.size), moov.length < 64 << 20,
              let data = file.read(at: moov.start, count: Int(moov.length)) else { return result }
        let top = Box.list(data, from: 0)
        var keys: [String] = []
        var appleDate: Date?

        if let mvhd = top.first(where: { $0.type == "mvhd" }) {
            let version = byte(data, mvhd.body)
            let seconds = version == 1 ? UInt64(readBE32(data, mvhd.body + 4)) << 32 | UInt64(readBE32(data, mvhd.body + 8))
                                       : UInt64(readBE32(data, mvhd.body + 4))
            // Seconds since 1904; 0 means unknown.
            if seconds > 0 { result.metadata.captureDate = Date(timeIntervalSince1970: Double(seconds) - 2_082_844_800) }
        }
        for trak in top where trak.type == "trak" {
            guard let tkhd = Box.list(data, from: trak.body, until: trak.end).first(where: { $0.type == "tkhd" }) else { continue }
            let version = byte(data, tkhd.body)
            let sizeAt = tkhd.body + (version == 1 ? 88 : 76)
            guard sizeAt + 8 <= tkhd.end else { continue }
            let width = Int(readBE32(data, sizeAt) >> 16), height = Int(readBE32(data, sizeAt + 4) >> 16)
            if width > 0 && height > 0 && result.metadata.pixelWidth == nil {
                result.metadata.pixelWidth = width
                result.metadata.pixelHeight = height
            }
        }
        // Classic user data: ©mak, ©mod, ©xyz.
        if let udta = top.first(where: { $0.type == "udta" }) {
            for item in Box.list(data, from: udta.body, until: udta.end) {
                guard item.body + 4 <= item.end else { continue }
                let length = Int(readBE16(data, item.body))
                let textStart = item.body + 4
                guard textStart + length <= item.end else { continue }
                let text = String(decoding: data[textStart..<textStart + length], as: UTF8.self)
                switch item.type {
                case "\u{A9}mak": result.metadata.make = text.trimmingCharacters(in: .whitespaces)
                case "\u{A9}mod": result.metadata.model = text.trimmingCharacters(in: .whitespaces)
                case "\u{A9}xyz": setLocation(text, &result)
                default: break
                }
            }
        }
        // QuickTime metadata (what iPhones write): moov/meta with `keys` and `ilst`.
        if let meta = top.first(where: { $0.type == "meta" }) {
            // QuickTime's `meta` holds boxes straight away; MP4's is a full box, with 4 bytes of version and flags first.
            let isQuickTimeStyle = meta.body + 8 <= meta.end
                && String(decoding: data[(meta.body + 4)..<(meta.body + 8)], as: UTF8.self) == "hdlr"
            let children = Box.list(data, from: meta.body + (isQuickTimeStyle ? 0 : 4), until: meta.end)
            if let keysBox = children.first(where: { $0.type == "keys" }) {
                let count = Int(readBE32(data, keysBox.body + 4))
                var cursor = keysBox.body + 8
                for _ in 0..<count where cursor + 8 <= keysBox.end {
                    let size = Int(readBE32(data, cursor))
                    guard size >= 8, cursor + size <= keysBox.end else { break }
                    keys.append(String(decoding: data[(cursor + 8)..<(cursor + size)], as: UTF8.self))
                    cursor += size
                }
            }
            if let ilst = children.first(where: { $0.type == "ilst" }) {
                var cursor = ilst.body
                while cursor + 8 <= ilst.end {
                    let size = Int(readBE32(data, cursor))
                    guard size >= 8, cursor + size <= ilst.end else { break }
                    let index = Int(readBE32(data, cursor + 4)) - 1
                    if index >= 0, index < keys.count,
                       let value = Box.list(data, from: cursor + 8, until: cursor + size).first(where: { $0.type == "data" }),
                       value.body + 8 <= value.end {
                        let text = String(decoding: data[(value.body + 8)..<value.end], as: UTF8.self)
                        switch keys[index] {
                        case "com.apple.quicktime.make": result.metadata.make = text
                        case "com.apple.quicktime.model": result.metadata.model = text
                        case "com.apple.quicktime.location.ISO6709": setLocation(text, &result)
                        case "com.apple.quicktime.creationdate": appleDate = parseISODate(text)
                        default: break
                        }
                    }
                    cursor += size
                }
            }
        }
        if let appleDate { result.metadata.captureDate = appleDate }
        return result
    }

    static func setLocation(_ text: String, _ result: inout Result) {
        guard let (lat, lon) = parseISO6709(text), !(lat == 0 && lon == 0) else { return }
        result.metadata.latitude = lat
        result.metadata.longitude = lon
    }

    // MARK: EXIF (TIFF structure)

    static func apply(tiff: [UInt8], to result: inout Result) {
        guard tiff.count >= 8 else { return }
        let little: Bool
        switch (tiff[0], tiff[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return
        }
        let reader = TIFFReader(data: tiff, little: little)
        let ifd0 = reader.entries(at: Int(reader.u32(4)))
        var dateOriginal: String?, offset: String?
        for entry in ifd0 {
            switch entry.tag {
            case 0x010F: result.metadata.make = reader.string(entry)?.trimmingCharacters(in: .whitespaces)
            case 0x0110: result.metadata.model = reader.string(entry)?.trimmingCharacters(in: .whitespaces)
            case 0x0112: result.orientation = Int(reader.integer(entry) ?? 1)
            case 0x8769:
                for exif in reader.entries(at: Int(reader.integer(entry) ?? 0)) {
                    switch exif.tag {
                    case 0x9003: dateOriginal = reader.string(exif)
                    case 0x9011: offset = reader.string(exif)
                    case 0x9286:
                        if let comment = reader.userComment(exif), comment.localizedCaseInsensitiveContains("screenshot") {
                            result.metadata.isScreenshot = true
                        }
                    case 0xA002: result.metadata.pixelWidth = reader.integer(exif).map(Int.init) ?? result.metadata.pixelWidth
                    case 0xA003: result.metadata.pixelHeight = reader.integer(exif).map(Int.init) ?? result.metadata.pixelHeight
                    default: break
                    }
                }
            case 0x8825:
                var lat: Double?, lon: Double?, latRef = "N", lonRef = "E"
                for gps in reader.entries(at: Int(reader.integer(entry) ?? 0)) {
                    switch gps.tag {
                    case 1: latRef = reader.string(gps) ?? latRef
                    case 2: lat = reader.degrees(gps)
                    case 3: lonRef = reader.string(gps) ?? lonRef
                    case 4: lon = reader.degrees(gps)
                    default: break
                    }
                }
                if var lat, var lon, !(lat == 0 && lon == 0) {
                    if latRef.uppercased() == "S" { lat = -lat }
                    if lonRef.uppercased() == "W" { lon = -lon }
                    result.metadata.latitude = lat
                    result.metadata.longitude = lon
                }
            default: break
            }
        }
        if let dateOriginal { result.metadata.captureDate = parseExifDate(dateOriginal, offset: offset) }
    }

    // MARK: Dates and places (shared with the Apple reader)

    /// EXIF dates look like `2026:11:02 18:41:07`, with an optional offset like `+01:00`.
    public static func parseExifDate(_ value: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset, !offset.isEmpty {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: value + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: value)
    }

    /// `2026-11-02T18:41:07+0100`, with or without seconds' fractions or a time zone.
    public static func parseISODate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for format in ["yyyy-MM-dd'T'HH:mm:ssxx", "yyyy-MM-dd'T'HH:mm:ssxxx", "yyyy-MM-dd'T'HH:mm:ss.SSSxxx",
                       "yyyy-MM-dd'T'HH:mm:ss.SSxxx", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            formatter.timeZone = format.hasSuffix("ss") ? .current : nil
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Parses `+38.7223-009.1393+045.000/` into latitude and longitude.
    public static func parseISO6709(_ value: String) -> (Double, Double)? {
        let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let latRange = Range(match.range(at: 1), in: value),
              let lonRange = Range(match.range(at: 2), in: value),
              let lat = Double(value[latRange]), let lon = Double(value[lonRange]) else { return nil }
        return (lat, lon)
    }
}

// MARK: - Reading helpers

/// A byte, or 0 past the end: a malformed file must not crash the reader.
func byte(_ data: [UInt8], _ at: Int) -> UInt8 {
    at >= 0 && at < data.count ? data[at] : 0
}

func readBE16(_ data: [UInt8], _ at: Int) -> UInt16 {
    guard at + 2 <= data.count else { return 0 }
    return UInt16(data[at]) << 8 | UInt16(data[at + 1])
}

func readBE32(_ data: [UInt8], _ at: Int) -> UInt32 {
    guard at + 4 <= data.count else { return 0 }
    return UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
}

/// An ISO base media box (HEIF, MP4, MOV) inside a byte array.
struct Box {
    let type: String
    /// Where its content starts and where the box ends, as indexes into the array.
    let body: Int
    let end: Int

    static func list(_ data: [UInt8], from start: Int, until limit: Int? = nil) -> [Box] {
        let limit = min(limit ?? data.count, data.count)
        var boxes: [Box] = []
        var cursor = start
        while cursor + 8 <= limit {
            var size = Int(readBE32(data, cursor))
            var header = 8
            if size == 1, cursor + 16 <= limit {
                size = Int(UInt64(readBE32(data, cursor + 8)) << 32 | UInt64(readBE32(data, cursor + 12)))
                header = 16
            } else if size == 0 {
                size = limit - cursor
            }
            guard size >= header, cursor + size <= limit else { break }
            boxes.append(Box(type: String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self),
                             body: cursor + header, end: cursor + size))
            cursor += size
        }
        return boxes
    }
}

/// Reads parts of a file without loading all of it (videos run to gigabytes).
final class FileReader {
    private let handle: FileHandle
    let size: UInt64

    init?(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else { return nil }
        self.handle = handle
        self.size = size
    }

    func read(at offset: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, offset < size else { return nil }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count) else { return nil }
            return [UInt8](data)
        } catch {
            return nil
        }
    }

    /// A top-level box: where it starts (after its header) and its length without the header.
    func findBox(_ type: String, in range: Range<UInt64>) -> (start: UInt64, length: UInt64)? {
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound, let header = read(at: cursor, count: 16), header.count >= 8 {
            var size = UInt64(readBE32(header, 0))
            var headerSize: UInt64 = 8
            if size == 1, header.count == 16 {
                size = UInt64(readBE32(header, 8)) << 32 | UInt64(readBE32(header, 12))
                headerSize = 16
            } else if size == 0 {
                size = range.upperBound - cursor
            }
            guard size >= headerSize else { return nil }
            if String(decoding: header[4..<8], as: UTF8.self) == type {
                return (cursor + headerSize, size - headerSize)
            }
            cursor += size
        }
        return nil
    }

    func close() { try? handle.close() }
}

/// EXIF's TIFF structure: directories of tagged values, in either byte order.
struct TIFFReader {
    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        /// Where the value is: inline in the entry when it fits in 4 bytes, else at an offset.
        let valueAt: Int
    }

    let data: [UInt8]
    let little: Bool

    func u16(_ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= data.count else { return 0 }
        return little ? UInt16(data[at]) | UInt16(data[at + 1]) << 8 : UInt16(data[at]) << 8 | UInt16(data[at + 1])
    }

    func u32(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= data.count else { return 0 }
        let b = (UInt32(data[at]), UInt32(data[at + 1]), UInt32(data[at + 2]), UInt32(data[at + 3]))
        return little ? b.0 | b.1 << 8 | b.2 << 16 | b.3 << 24 : b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3
    }

    func entries(at offset: Int) -> [Entry] {
        guard offset > 0, offset + 2 <= data.count else { return [] }
        let count = Int(u16(offset))
        guard count < 1000 else { return [] }
        let sizes: [UInt16: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8]
        return (0..<count).compactMap { index in
            let at = offset + 2 + index * 12
            guard at + 12 <= data.count else { return nil }
            let type = u16(at + 2), count = u32(at + 4)
            let bytes = (sizes[type] ?? 1) * Int(count)
            return Entry(tag: u16(at), type: type, count: count, valueAt: bytes <= 4 ? at + 8 : Int(u32(at + 8)))
        }
    }

    func string(_ entry: Entry) -> String? {
        let end = entry.valueAt + Int(entry.count)
        guard entry.valueAt >= 0, end <= data.count, entry.count > 0 else { return nil }
        let bytes = data[entry.valueAt..<end].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    func integer(_ entry: Entry) -> UInt32? {
        switch entry.type {
        case 3: return UInt32(u16(entry.valueAt))
        case 4, 9: return u32(entry.valueAt)
        default: return nil
        }
    }

    /// Three rationals — degrees, minutes, seconds — as decimal degrees.
    func degrees(_ entry: Entry) -> Double? {
        guard entry.type == 5, entry.count >= 3 else { return nil }
        var parts: [Double] = []
        for i in 0..<3 {
            let numerator = Double(u32(entry.valueAt + i * 8)), denominator = Double(u32(entry.valueAt + i * 8 + 4))
            guard denominator != 0 else { return nil }
            parts.append(numerator / denominator)
        }
        return parts[0] + parts[1] / 60 + parts[2] / 3600
    }

    /// An 8-byte character code ("ASCII", "UNICODE"), then the text.
    func userComment(_ entry: Entry) -> String? {
        let end = entry.valueAt + Int(entry.count)
        guard entry.count > 8, entry.valueAt >= 0, end <= data.count else { return nil }
        let code = String(decoding: data[entry.valueAt..<(entry.valueAt + 8)].prefix { $0 != 0 }, as: UTF8.self)
        let body = Array(data[(entry.valueAt + 8)..<end])
        if code == "UNICODE" {
            let units = stride(from: 0, to: body.count - 1, by: 2).map {
                little ? UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8 : UInt16(body[$0]) << 8 | UInt16(body[$0 + 1])
            }
            return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
        }
        return String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
    }
}
