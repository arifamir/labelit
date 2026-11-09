#if canImport(FoundationModels)
import Foundation
import FoundationModels
import LabelItCore

@Generable
struct GeneratedLabel {
    @Guide(description: "A short descriptive file name: 2 to 5 lowercase English words joined by hyphens, e.g. stripe-checkout-payment-declined or dog-running-on-beach. Name the specific subject, product, site or app. No dates, no file extension.")
    var slug: String
}

/// Names files with Apple's on-device model. The model reads text only, so it is given
/// Vision's findings, the capture context and the metadata, then writes the name.
/// Falls back to `RuleNamer` when Apple Intelligence is off, busy or refuses.
public struct AppleIntelligenceNamer: Namer {
    let fallback: RuleNamer
    let timeout: Duration

    public init(fallback: RuleNamer = RuleNamer(), timeout: Duration = .seconds(12)) {
        self.fallback = fallback
        self.timeout = timeout
    }

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Human-readable reason when the model can't be used.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Turn it on in System Settings for better names."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    public func name(_ facts: FileFacts) async -> NamingResult {
        let kind = KindDetector.detect(facts)
        guard Self.isAvailable else { return await fallback.name(facts) }

        let prompt = NamingPrompt.prompt(for: facts, kind: kind)
        let slug: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: NamingPrompt.instructions)
                let response = try? await session.respond(
                    to: prompt, generating: GeneratedLabel.self,
                    options: GenerationOptions(sampling: .greedy))
                return response?.content.slug
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        let cleaned = NamingPrompt.dropFiller(Slug.make(slug ?? "", maxWords: 6, maxLength: 50))
        guard cleaned.count >= 3, NamingPrompt.isSpecificEnough(cleaned, for: facts) else { return await fallback.name(facts) }
        return NamingResult(slug: cleaned, kind: kind, namer: .appleIntelligence)
    }
}
#endif
