import Foundation
import Testing
@testable import LabelItCore
@testable import LabelItPlatform
#if canImport(CoreText)
import CoreGraphics
import CoreText
import ImageIO
#endif

/// The platform's own reader and text reader (Vision on a Mac, Tesseract on Linux), with the rule namer so names
/// are the same everywhere.
func makeLabeler(log: RenameLog) -> Labeler {
    Labeler(reader: NativePlatform.reader(), understanding: NativePlatform.understanding(), namer: RuleNamer(), log: log)
}

/// End-to-end: real images, the platform's real text reader, real renames, in a temp folder.
@Suite(.serialized) struct PipelineTests {
    @Test func captureOfAnErrorIsNamedFromItsText() async throws {
        let dir = try TempDir()
        let temp = dir.url.appendingPathComponent("capture-tmp.png")
        try Fixtures.writeImage(to: temp, type: .png, lines: [("Checkout", 64), ("Your payment was declined", 40),
                                                              ("Please try another card", 28)])
        let destination = dir.url.appendingPathComponent("Screenshots")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let labeler = makeLabeler(log: RenameLog(fileURL: dir.url.appendingPathComponent("h.json")))
        let entry = try await labeler.labelCapture(temp, context: nil, into: destination)

        #expect(entry.kind == .error)
        #expect(entry.newName.hasPrefix("your-payment-was-declined_"))
        #expect(entry.newName.hasSuffix(".png"))
        let renamed = URL(fileURLWithPath: entry.primary.to)
        #expect(renamed.deletingLastPathComponent().lastPathComponent == "Screenshots")
        #expect(FileMarkers.isProcessed(renamed))
        #expect(FileMarkers.tags(at: renamed) == ["Error"])
    }

    @Test func phonePhotoAndItsLivePhotoVideoAreRenamedTogetherAndCanBeUndone() async throws {
        let dir = try TempDir()
        let image = dir.url.appendingPathComponent("IMG_4821.JPG")
        try Fixtures.writeImage(to: image, type: .jpeg, lines: [("Sunday Market", 50)], iPhone: true)
        let video = dir.url.appendingPathComponent("IMG_4821.MOV")
        FileManager.default.createFile(atPath: video.path, contents: Data("not really a movie".utf8))

        let log = RenameLog(fileURL: dir.url.appendingPathComponent("h.json"))
        let labeler = makeLabeler(log: log)

        #expect(await labeler.classify(image, requireRecent: true) == .phone)
        // The video waits for its image.
        #expect(await labeler.plan(video, source: .phone, context: nil) == nil)

        let proposal = try #require(await labeler.plan(image, source: .phone, context: nil))
        #expect(proposal.moves.count == 2)
        #expect(proposal.newName.contains("_2026-11-02"))
        #expect(proposal.whereFroms == ["iPhone 16 Pro"])

        let entry = try await labeler.apply(proposal)
        let newImage = URL(fileURLWithPath: entry.moves[0].to)
        let newVideo = URL(fileURLWithPath: entry.moves[1].to)
        #expect(newImage.deletingPathExtension().lastPathComponent == newVideo.deletingPathExtension().lastPathComponent)
        #expect(newImage.pathExtension == "jpg" && newVideo.pathExtension == "mov")
        #expect(!FileManager.default.fileExists(atPath: image.path))
        #if os(Linux)
        #expect(FileMarkers.whereFroms(newImage).isEmpty)   // Linux keeps only a web address there
        #else
        #expect(FileMarkers.whereFroms(newImage) == ["iPhone 16 Pro"])
        #endif

        // Already handled: never again.
        #expect(await labeler.classify(newImage, requireRecent: true) == nil)

        try await Task.sleep(for: .milliseconds(100))
        try await log.undo(entry.id)
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect(FileManager.default.fileExists(atPath: video.path))
        #expect(!FileManager.default.fileExists(atPath: newImage.path))
        await #expect(throws: UndoError.alreadyUndone) { try await log.undo(entry.id) }
    }

    /// AirDrop gives a received photo the photo's own creation date (when it was taken), not when it arrived.
    @Test func anAirDroppedPhotoTakenDaysAgoIsStillNew() async throws {
        let dir = try TempDir()
        let staging = dir.url.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let received = staging.appendingPathComponent("IMG_7426.JPG")
        try Fixtures.writeImage(to: received, type: .jpeg, lines: [("Sunday Market", 50)], iPhone: true)
        let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
        try FileManager.default.setAttributes([.creationDate: threeDaysAgo, .modificationDate: threeDaysAgo],
                                              ofItemAtPath: received.path)
        // Then it's moved into the watched folder, as AirDrop moves it into Downloads.
        let arrived = dir.url.appendingPathComponent("IMG_7426.JPG")
        try FileManager.default.moveItem(at: received, to: arrived)

        let labeler = makeLabeler(log: RenameLog(fileURL: dir.url.appendingPathComponent("h.json")))
        #expect(await labeler.classify(arrived, requireRecent: true) == .phone)
    }

    @Test func filesNamedOnPurposeAreLeftAlone() async throws {
        let dir = try TempDir()
        let image = dir.url.appendingPathComponent("passport-scan.jpg")
        try Fixtures.writeImage(to: image, type: .jpeg, lines: [("Passport", 40)], iPhone: true)
        let labeler = makeLabeler(log: RenameLog(fileURL: dir.url.appendingPathComponent("h.json")))
        #expect(await labeler.classify(image, requireRecent: true) == nil)
    }

    @Test func filesPickedInFinderAreRenamedWhateverTheirName() async throws {
        let dir = try TempDir()
        // A web download: deliberate-looking name, no camera, PNG → treated as a screen and named from its text.
        let download = dir.url.appendingPathComponent("final-v2.png")
        try Fixtures.writeImage(to: download, type: .png, lines: [("Pricing Plans", 64), ("Compare every plan", 30)])
        let notes = dir.url.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: notes.path, contents: Data("hello".utf8))

        let labeler = makeLabeler(log: RenameLog(fileURL: dir.url.appendingPathComponent("h.json")))
        // The watchers would leave it alone…
        #expect(await labeler.classify(download, requireRecent: true) == nil)
        // …but picking it is asking. The text file isn't a picture and stays put.
        let entries = await labeler.renameChosen([notes, download])
        #expect(entries.count == 1)
        #expect(entries.first?.source == .finder)
        #expect(entries.first?.newName.hasPrefix("pricing-plans_") == true)
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(!FileManager.default.fileExists(atPath: download.path))
    }

    @Test func screenshotsRenamedByHandAreLeftAlone() async throws {
        let dir = try TempDir()
        let labeler = makeLabeler(log: RenameLog(fileURL: dir.url.appendingPathComponent("h.json")))
        let names = ["Screenshot 2026-11-08 at 10.41.07.png": true,
                     "Bildschirmfoto 2026-11-08 um 10.41.07.png": true,
                     "スクリーンショット 2026-11-08 10.41.07.png": true,
                     "boarding-pass.png": false]
        for (name, expected) in names {
            let url = dir.url.appendingPathComponent(name)
            try Fixtures.writeImage(to: url, type: .png, lines: [("Hello", 40)])
            // macOS marks its screenshots; elsewhere they're known by name.
            ExtendedAttributes.set(FileMarkers.isScreenCapture, data: Data([1]), at: url)
            #expect((await labeler.classify(url, requireRecent: true) == .screenshot) == expected, "\(name)")
        }
    }

    @Test func undoWontTouchADifferentFileThatTookTheName() async throws {
        let dir = try TempDir()
        let image = dir.url.appendingPathComponent("IMG_0001.JPG")
        try Fixtures.writeImage(to: image, type: .jpeg, lines: [("Sunday Market", 50)], iPhone: true)
        let log = RenameLog(fileURL: dir.url.appendingPathComponent("h.json"))
        let labeler = makeLabeler(log: log)
        let entry = try #require(await labeler.handleNewFile(image))
        let renamed = URL(fileURLWithPath: entry.primary.to)

        // The renamed photo is deleted, and an unrelated file later gets the same name.
        try FileManager.default.removeItem(at: renamed)
        FileManager.default.createFile(atPath: renamed.path, contents: Data("someone else".utf8))
        await #expect(throws: UndoError.fileMissing(renamed.lastPathComponent)) { try await log.undo(entry.id) }
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }

    @Test func capturesCantBeUndoneIntoTheTempFolder() async throws {
        let dir = try TempDir()
        let temp = dir.url.appendingPathComponent("capture-tmp.png")
        try Fixtures.writeImage(to: temp, type: .png, lines: [("Settings", 50)])
        let log = RenameLog(fileURL: dir.url.appendingPathComponent("h.json"))
        let labeler = makeLabeler(log: log)
        let entry = try await labeler.labelCapture(temp, context: nil, into: dir.url)
        #expect(!entry.canUndo)
        await #expect(throws: UndoError.notUndoable) { try await log.undo(entry.id) }
        // Logged before labelCapture returned.
        #expect(await log.recent(1).first?.id == entry.id)
    }

    @Test func aLivePhotoPairSharesOneFreeName() throws {
        let dir = try TempDir()
        let builder = FilenameBuilder()
        FileManager.default.createFile(atPath: dir.url.appendingPathComponent("dog.heic").path, contents: Data())
        #expect(builder.availableBase(in: dir.url, base: "dog", exts: ["HEIC", "MOV"]) == "dog-2")
        FileManager.default.createFile(atPath: dir.url.appendingPathComponent("dog-2.mov").path, contents: Data())
        #expect(builder.availableBase(in: dir.url, base: "dog", exts: ["HEIC", "MOV"]) == "dog-3")
    }

    @Test func downloadsStillArrivingAreIgnored() throws {
        let root = URL(fileURLWithPath: "/tmp/labelit-watch")
        let watcher = FolderWatcher(folders: [root]) { _ in }
        #expect(watcher.shouldConsider("/tmp/labelit-watch/IMG_1.HEIC"))
        #expect(!watcher.shouldConsider("/tmp/labelit-watch/IMG_1.HEIC.download/IMG_1.HEIC"))
        #expect(!watcher.shouldConsider("/tmp/labelit-watch/IMG_1.HEIC.crdownload"))
    }

    @Test func pastFilesArePlannedWithoutRenaming() async throws {
        let dir = try TempDir()
        for n in 1...3 {
            try Fixtures.writeImage(to: dir.url.appendingPathComponent("IMG_000\(n).JPG"), type: .jpeg,
                                    lines: [("Note \(n)", 40)], iPhone: true)
        }
        try Fixtures.writeImage(to: dir.url.appendingPathComponent("IMG_0009.JPG"), type: .jpeg,
                                lines: [("Not from a phone", 40)], iPhone: false)
        let labeler = makeLabeler(log: RenameLog(fileURL: dir.url.appendingPathComponent("h.json")))
        let proposals = await labeler.planPastFiles(in: dir.url)
        #expect(proposals.count == 3)
        #expect(Set(proposals.map(\.newName)).count == 3)
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("IMG_0001.JPG").path))
    }
}

enum Fixtures {
    enum ImageType: String { case png, jpeg }

    /// Committed test images, so every platform reads the same pixels. A Mac renders any that are missing.
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// Copies the fixture showing these lines of text (black on white), optionally with iPhone EXIF, to `url`.
    static func writeImage(to url: URL, type: ImageType, lines: [(String, Double)], iPhone: Bool = false) throws {
        let source = folder.appendingPathComponent(name(type: type, lines: lines, iPhone: iPhone))
        if !FileManager.default.fileExists(atPath: source.path) {
            #if canImport(CoreText)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try render(to: source, type: type, lines: lines, iPhone: iPhone)
            #else
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path,
                NSLocalizedDescriptionKey: "Missing fixture \(source.lastPathComponent): run the tests on a Mac to render it."])
            #endif
        }
        // A new file, not a copy: macOS copies keep the original's creation date, and LabelIt only handles new files.
        try Data(contentsOf: source).write(to: url)
    }

    static func name(type: ImageType, lines: [(String, Double)], iPhone: Bool) -> String {
        let text = lines.map(\.0).joined(separator: " ").lowercased()
        let slug = text.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return String(slug.prefix(60)) + (iPhone ? "_iphone" : "") + (type == .png ? ".png" : ".jpg")
    }

    #if canImport(CoreText)
    /// Draws black text on white and saves it, optionally with iPhone EXIF.
    static func render(to url: URL, type: ImageType, lines: [(String, Double)], iPhone: Bool) throws {
        let width = 1400, height = 900
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var y = CGFloat(height) - 120
        for (text, size) in lines {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 80, y: y)
            CTLineDraw(line, context)
            y -= size * 2.2
        }
        let typeID = type == .png ? "public.png" : "public.jpeg"
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, typeID as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties: [CFString: Any] = [:]
        if iPhone {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Apple",
                                                          kCGImagePropertyTIFFModel: "iPhone 16 Pro"]
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:11:02 18:41:07",
                                                          kCGImagePropertyExifOffsetTimeOriginal: "+00:00"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
    #endif
}

#if os(macOS)
/// The plain-Swift metadata reader (Linux, Windows) must agree with ImageIO and AVFoundation.
/// Set LABELIT_COMPARE_DIR to also compare every picture and video in a folder (read only).
@Suite struct MetadataParserParityTests {
    @Test func agreesWithApplesReadersOnTheFixtures() async throws {
        let files = try FileManager.default.contentsOfDirectory(at: Fixtures.folder, includingPropertiesForKeys: nil)
        let mismatches = await Self.compare(files)
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LABELIT_COMPARE_DIR"] != nil))
    func agreesWithApplesReadersOnRealFiles() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LABELIT_COMPARE_DIR"]!)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let mismatches = await Self.compare(files)
        var dated = 0, located = 0, phones = 0, screenshots = 0, kinds: [String: Int] = [:]
        for url in files where AppleMediaReader().isMedia(url) {
            let found = MetadataParser.read(url).metadata
            if found.captureDate != nil { dated += 1 }
            if found.latitude != nil { located += 1 }
            if found.isFromAppleMobileDevice { phones += 1 }
            if found.isScreenshot { screenshots += 1 }
            kinds[url.pathExtension.lowercased(), default: 0] += 1
        }
        print("Compared \(kinds.values.reduce(0, +)) pictures and videos \(kinds.sorted { $0.key < $1.key }): \(dated) dated, "
              + "\(located) with a location, \(phones) from an iPhone or iPad, \(screenshots) screenshots; \(mismatches.count) differ")
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
    }

    static func compare(_ files: [URL]) async -> [String] {
        let apple = AppleMediaReader()
        var mismatches: [String] = []
        for url in files where apple.isMedia(url) {
            let expected = await apple.metadata(of: url)
            var actual = MetadataParser.read(url).metadata
            // The Spotlight screenshot marker is an extended attribute, not file content: both readers see it there.
            if FileMarkers.isMacScreenshot(url) { actual.isScreenshot = true }
            var problems: [String] = []
            if expected.make != actual.make { problems.append("make \(expected.make ?? "-") / \(actual.make ?? "-")") }
            if expected.model != actual.model { problems.append("model \(expected.model ?? "-") / \(actual.model ?? "-")") }
            if expected.isScreenshot != actual.isScreenshot { problems.append("screenshot \(expected.isScreenshot) / \(actual.isScreenshot)") }
            switch (expected.captureDate, actual.captureDate) {
            case let (a?, b?) where abs(a.timeIntervalSince(b)) > 1: problems.append("date \(a) / \(b)")
            case (.some, nil), (nil, .some): problems.append("date \(String(describing: expected.captureDate)) / \(String(describing: actual.captureDate))")
            default: break
            }
            if let a = expected.latitude, let b = actual.latitude, abs(a - b) > 0.0001 { problems.append("latitude \(a) / \(b)") }
            if (expected.latitude == nil) != (actual.latitude == nil) { problems.append("location \(String(describing: expected.latitude)) / \(String(describing: actual.latitude))") }
            if let a = expected.longitude, let b = actual.longitude, abs(a - b) > 0.0001 { problems.append("longitude \(a) / \(b)") }
            if !problems.isEmpty { mismatches.append("\(url.lastPathComponent): " + problems.joined(separator: ", ")) }
        }
        return mismatches
    }
}
#endif

@Suite struct WatcherPathTests {
    /// FSEvents reports real paths (/private/tmp/…); a folder given through a symlink must still match them.
    @Test func eventsMatchFoldersGivenThroughSymlinks() throws {
        let dir = try TempDir()
        let real = dir.url.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.url.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let watcher = FolderWatcher(folders: [link]) { _ in }
        // On a Mac the temporary folder is under /private/var, which URL.resolvingSymlinksInPath would have dropped.
        #expect(watcher.shouldConsider(Paths.canonical(real) + "/IMG_1.HEIC"))
    }
}

#if os(macOS)
/// PDFs picked in Finder: named from a meaningful title, else from the first page's heading.
@Suite(.serialized) struct PDFTests {
    @Test func aPDFWithAnIDForANameIsNamedFromItsHeading() async throws {
        let dir = try TempDir()
        let pdf = dir.url.appendingPathComponent("UC-c796945e-d9b7-4638-b2e3-b9edd6c4b16f.pdf")
        // Laid out like a course certificate: a small "certificate" line, then a big title that wraps onto two lines.
        try Self.writePDF(to: pdf, title: nil, lines: [("CERTIFICATE OF COMPLETION", 14), ("Swift Concurrency", 40),
                                                       ("Masterclass for iOS", 40), ("Instructors Jane Appleseed", 14),
                                                       ("Arif Amir", 28)])
        let labeler = makeLabeler(log: RenameLog(fileURL: dir.url.appendingPathComponent("h.json")))
        // The watchers never rename documents…
        #expect(await labeler.classify(pdf, requireRecent: true) == nil)
        // …but picking one is asking.
        let entry = try #require(await labeler.renameChosen([pdf]).first)
        #expect(entry.kind == .document && entry.source == .finder)
        #expect(entry.newName.hasPrefix("certificate-swift-concurrency-masterclass-ios_"), "\(entry.newName)")
        #expect(entry.newName.hasSuffix(".pdf"))
    }

    @Test func aMeaningfulTitleNamesThePDF() async throws {
        let dir = try TempDir()
        let pdf = dir.url.appendingPathComponent("scan0001.pdf")
        try Self.writePDF(to: pdf, title: "Quarterly Report Q3 2026", lines: [("Contents", 30), ("1. Overview", 20)])
        let labeler = makeLabeler(log: RenameLog(fileURL: dir.url.appendingPathComponent("h.json")))
        let entry = try #require(await labeler.renameChosen([pdf]).first)
        #expect(entry.newName.hasPrefix("quarterly-report-q3-2026_"))
    }

    /// One A4 page of black text on white, with an optional title in the document's metadata.
    static func writePDF(to url: URL, title: String?, lines: [(String, CGFloat)]) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        var y: CGFloat = 760
        for (text, size) in lines {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            context.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            y -= size * 2.4
        }
        context.endPDFPage()
        context.closePDF()
    }
}
#endif
