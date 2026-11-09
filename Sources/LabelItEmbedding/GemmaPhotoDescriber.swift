import Foundation
import LabelItCore

/// Describes photos with EmbeddingGemma 2: the photo's vector is compared with every phrase in `Vocabulary`,
/// and the best match in each group becomes a word when it stands out from the rest of its group.
///
/// The model (about 1 GB) loads on first use and unloads after `idleUnload` without photos.
public actor GemmaPhotoDescriber: PhotoDescriber {
    public struct Match: Sendable {
        public let concept: Vocabulary.Concept
        public let score: Float
        /// How far above the group's average this score is, in standard deviations.
        public let zScore: Float
    }

    public struct Description: Sendable {
        public var chosen: [String]
        public var ranked: [Vocabulary.Group: [Match]]
        public var seconds: Double
    }

    /// A best match counts only this far above its group's average (in standard deviations).
    /// Tuned on real phone photos with `labelit-cli describe`.
    /// Measured on 28 phone photos (2026-11-09): true subjects scored z 3.4–5.6, wrong guesses up to 3.1.
    public static let thresholds: [Vocabulary.Group: Float] = [.subject: 3.3, .setting: 3.0, .light: 3.0]

    private let files: ModelFiles.Located
    private let idleUnload: Duration
    private var embedder: GemmaEmbedder?
    private var concepts: [Vocabulary.Group: (items: [Vocabulary.Concept], vectors: [[Float]])] = [:]
    private var unloadTask: Task<Void, Never>?
    /// Bumped on every use, so an idle timer that already fired can't unload the model mid-batch.
    private var generation = 0
    /// Set when the app quits: llama.cpp aborts if the process exits with a model loaded, so no reloading after.
    private var isShutDown = false

    public init(files: ModelFiles.Located, idleUnload: Duration = .seconds(90)) {
        self.files = files
        self.idleUnload = idleUnload
    }

    public var isLoaded: Bool { embedder != nil }

    public func describe(_ picture: any Pixels) async -> [String] {
        do {
            return try analyze(picture).chosen
        } catch {
            FileHandle.standardError.write(Data("LabelIt: EmbeddingGemma couldn't describe a photo: \(error)\n".utf8))
            return []
        }
    }

    public func analyze(_ image: any Pixels) throws -> Description {
        let started = Date()
        let embedder = try loaded()
        defer { scheduleUnload() }
        let vector = try embedder.embed(image: image)

        var ranked: [Vocabulary.Group: [Match]] = [:]
        var chosen: [String] = []
        // Every phrase's score, to judge each group's best match against all of them: a group of 8
        // (sunset, night…) is too small for its own statistics.
        var scoresByGroup: [Vocabulary.Group: [Float]] = [:]
        for group in Vocabulary.Group.allCases {
            scoresByGroup[group] = concepts[group]?.vectors.map { dot($0, vector) } ?? []
        }
        let all = scoresByGroup.values.flatMap { $0 }
        let mean = all.reduce(0, +) / Float(max(all.count, 1))
        let variance = all.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(all.count, 1))
        let deviation = max(variance.squareRoot(), 1e-6)
        for group in Vocabulary.Group.allCases {
            guard let entry = concepts[group], let scores = scoresByGroup[group] else { continue }
            let matches = zip(entry.items, scores)
                .map { Match(concept: $0, score: $1, zScore: ($1 - mean) / deviation) }
                .sorted { $0.score > $1.score }
            ranked[group] = matches
            if let best = matches.first, best.zScore >= Self.thresholds[group, default: 3] {
                if !Self.isRedundant(best.concept.slug, after: chosen) { chosen.append(best.concept.slug) }
            }
        }
        return Description(chosen: chosen, ranked: ranked, seconds: Date().timeIntervalSince(started))
    }

    /// "garden" after "garden", "snowy" after "snow": the same thing said twice.
    static func isRedundant(_ slug: String, after chosen: [String]) -> Bool {
        let earlier = chosen.flatMap { $0.split(separator: "-").map(String.init) }
        return slug.split(separator: "-").allSatisfy { word in
            earlier.contains { $0.hasPrefix(word) || word.hasPrefix($0) }
        }
    }

    /// Frees the model for good: the app is quitting. Later photos go undescribed.
    public func shutDown() {
        isShutDown = true
        unload()
    }

    /// Frees the model now (it reloads on the next photo).
    public func unload() {
        unloadTask?.cancel()
        embedder?.close()
        embedder = nil
    }

    // MARK: Loading

    private func loaded() throws -> GemmaEmbedder {
        guard !isShutDown else { throw EmbeddingError("shutting down") }
        unloadTask?.cancel()
        generation += 1
        let embedder = try self.embedder ?? GemmaEmbedder(files: files)
        self.embedder = embedder
        // Also retried after a failure, rather than describing nothing until the next reload.
        if concepts.isEmpty { try loadConcepts(with: embedder) }
        return embedder
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        let delay = idleUnload
        let scheduledAt = generation
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle(since: scheduledAt)
        }
    }

    private func unloadIfIdle(since scheduledAt: Int) {
        guard generation == scheduledAt else { return }
        unload()
    }

    /// Phrase vectors, from the cache when the vocabulary and model haven't changed.
    private func loadConcepts(with embedder: GemmaEmbedder) throws {
        let groups = Vocabulary.Group.allCases.map { ($0, Vocabulary.groups[$0] ?? []) }
        let allTexts = groups.flatMap { $0.1.map(\.text) }
        let key = Self.cacheKey(for: allTexts)
        let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LabelIt/concepts-\(key).bin")

        var vectors: [[Float]]
        if let cached = Self.readVectors(cacheURL, count: allTexts.count) {
            vectors = cached
        } else {
            vectors = try embedder.embed(texts: allTexts.map { "task: search result | query: \($0)" })
            Self.writeVectors(vectors, to: cacheURL)
        }
        for (group, items) in groups {
            concepts[group] = (items, Array(vectors.prefix(items.count)))
            vectors.removeFirst(items.count)
        }
    }

    static func cacheKey(for texts: [String]) -> String {
        let material = ([ModelFiles.text.sha256, ModelFiles.media.sha256, "query-v1"] + texts).joined(separator: "\n")
        return String(Hashing.sha256Hex(Data(material.utf8)).prefix(16))
    }

    static func readVectors(_ url: URL, count: Int) -> [[Float]]? {
        guard let data = try? Data(contentsOf: url), count > 0 else { return nil }
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard floats.count % count == 0, !floats.isEmpty else { return nil }
        let size = floats.count / count
        return (0..<count).map { Array(floats[($0 * size)..<(($0 + 1) * size)]) }
    }

    static func writeVectors(_ vectors: [[Float]], to url: URL) {
        let flat = vectors.flatMap { $0 }
        let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

@inline(__always)
func dot(_ a: [Float], _ b: [Float]) -> Float {
    var sum: Float = 0
    for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
    return sum
}
