#if canImport(Vision)
import CoreGraphics
import Foundation
import LabelItCore
import Vision

/// On-device image understanding with Apple's Vision framework.
public struct VisionUnderstanding: ImageUnderstanding {
    public init() {}

    public func analyze(_ picture: any Pixels, readText: Bool) async -> ImageAnalysis {
        guard let image = CGPicture.cgImage(from: picture) else { return ImageAnalysis() }
        async let labels = classify(image)
        async let animals = recognizeAnimals(image)
        async let faces = countFaces(image)
        async let lines = readText ? recognizeText(image) : []
        return await ImageAnalysis(labels: labels, animals: animals, faceCount: faces, lines: lines, detectsObjects: true)
    }

    private func classify(_ image: CGImage) async -> [VisualLabel] {
        let results = (try? await ClassifyImageRequest().perform(on: image)) ?? []
        return results
            .filter { $0.confidence >= 0.15 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(12)
            .map { VisualLabel(name: $0.identifier, confidence: Double($0.confidence)) }
    }

    private func recognizeAnimals(_ image: CGImage) async -> [String] {
        let results = (try? await RecognizeAnimalsRequest().perform(on: image)) ?? []
        var names: [String] = []
        for observation in results {
            for label in observation.labels where label.confidence >= 0.5 {
                let name = label.identifier.lowercased()
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    private func countFaces(_ image: CGImage) async -> Int {
        let results = (try? await DetectFaceRectanglesRequest().perform(on: image)) ?? []
        // Ignore tiny faces in the background.
        return results.filter { $0.boundingBox.height >= 0.06 }.count
    }

    private func recognizeText(_ image: CGImage) async -> [TextLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let results = (try? await request.perform(on: image)) ?? []
        return results.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            // Vision's origin is bottom-left.
            return TextLine(text: text, height: Double(box.height), top: Double(1 - (box.origin.y + box.height)))
        }
        .sorted { $0.top < $1.top }
    }
}
#endif
