import AppKit
import CryptoKit
import Foundation
import Observation
import LabelItCore

/// Looks for a newer LabelIt on GitHub (one small request a day, nothing about the user is sent) and installs it when
/// asked, with the same checks as install.sh: the release's SHA-256, a valid signature, and LabelIt's own bundle ID.
@Observable
final class Updater {
    struct Release: Equatable {
        let version: String
        let tag: String
        let notes: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case updating(String)
        case failed(String)
    }

    static let repository = "arifamir/labelit"
    /// How often LabelIt looks, at most.
    static let interval: TimeInterval = 20 * 60 * 60

    private(set) var state: State = .idle
    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    /// Checks now and then while `enabled()` says so: soon after launch when a day has passed, then every hour sees
    /// whether a day has passed again.
    func startChecking(enabled: @escaping () -> Bool) {
        Task {
            try? await Task.sleep(for: .seconds(10))   // after launch work, not during it
            while !Task.isCancelled {
                if enabled(), Date().timeIntervalSince(lastCheck ?? .distantPast) >= Self.interval {
                    await check(quietly: true)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Asks GitHub for the latest release. Quietly: a failure leaves no message (no network, say).
    func check(quietly: Bool = false) async {
        if case .updating = state { return }
        if !quietly { state = .checking }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LabelIt/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        struct Latest: Decodable {
            let tag_name: String
            let html_url: URL
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub didn't answer") }
            let latest = try JSONDecoder().decode(Latest.self, from: data)
            lastCheck = Date()
            let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
            state = AppVersion.isNewer(version, than: currentVersion)
                ? .available(Release(version: version, tag: latest.tag_name, notes: latest.html_url))
                : .upToDate
        } catch {
            state = quietly ? .idle : .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    /// Downloads the release, checks it, puts it in place of this copy, and quits (freeing the model as any quit does)
    /// to reopen as the new version.
    func install(_ release: Release) async {
        let target = Bundle.main.bundleURL
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("labelit-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw UpdateError("LabelIt can't replace itself in \(target.deletingLastPathComponent().path). "
                                  + "Run the install command from the README instead.")
            }
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let base = URL(string: "https://github.com/\(Self.repository)/releases/download/\(release.tag)/")!

            state = .updating("Downloading LabelIt \(release.version)…")
            let zip = work.appendingPathComponent("LabelIt.zip")
            let (downloaded, response) = try await URLSession.shared.download(from: base.appendingPathComponent("LabelIt.zip"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("the download failed") }
            try FileManager.default.moveItem(at: downloaded, to: zip)
            let (sumData, sumResponse) = try await URLSession.shared.data(from: base.appendingPathComponent("LabelIt.zip.sha256"))
            guard (sumResponse as? HTTPURLResponse)?.statusCode == 200,
                  let expected = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init)
            else { throw UpdateError("the release has no checksum") }

            state = .updating("Checking the download…")
            let actual = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw UpdateError("the download doesn't match its checksum") }
            let unpacked = work.appendingPathComponent("unpacked")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let app = unpacked.appendingPathComponent("LabelIt.app")
            guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version
            else { throw UpdateError("the download isn't LabelIt \(release.version)") }
            try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

            state = .updating("Installing…")
            _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
            // Reopen once this copy has quit (only one LabelIt runs at a time).
            let reopen = Process()
            reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
            reopen.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                                target.path]
            try reopen.run()
            // From the run loop, as a click would: quitting waits for the model to be freed by a main-actor task, and
            // nothing else on the main queue runs while this task, or a main-queue block, is still running.
            RunLoop.main.perform { NSApp.terminate(nil) }
        } catch {
            state = .failed("Couldn't update: \((error as? UpdateError)?.message ?? error.localizedDescription)")
        }
    }

    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else {
            throw UpdateError(tool.hasSuffix("codesign") ? "the download's signature doesn't check out" : "couldn't unpack the download")
        }
    }
}

struct UpdateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
