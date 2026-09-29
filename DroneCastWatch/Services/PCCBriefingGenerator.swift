//
//  PCCBriefingGenerator.swift
//  DroneCast — Services layer (app target only)
//
//  The only file that imports FoundationModels.
//
//  watchOS 27 has NO on-device language model: SystemLanguageModel is not
//  available on watchOS, and Foundation Models on the watch always routes
//  to Apple's Private Cloud Compute over Wi-Fi or cellular. Using it needs
//  the managed Private Cloud Compute entitlement, which Apple grants only
//  to App Store Small Business Program members — i.e. not to free personal
//  teams. So, exactly like WeatherKit, it ships switched off.
//
//  To enable after qualifying:
//    1. Request the Private Cloud Compute entitlement
//       (developer.apple.com/private-cloud-compute) and add it to the app
//       target in Signing & Capabilities.
//    2. Flip BriefingConfig.useCloudModel to true.
//  Until then the app always shows the deterministic template briefing.
//

import Foundation
import FoundationModels

enum BriefingConfig {
    static let useCloudModel = false
}

// MARK: - Guided generation schema

@Generable(description: "A short pre-flight weather briefing for a drone pilot.")
struct GeneratedBriefing {
    @Guide(description: """
        At most 40 characters, for a watch complication. Start with the verdict \
        from FACTS exactly as written (GO, CAUTION or NO-GO), then the main reason.
        """)
    var headline: String

    @Guide(description: """
        One or two calm, plain sentences explaining the verdict for the aircraft \
        in FACTS. Quote numbers exactly as they appear in FACTS, as digits.
        """)
    var detail: String

    @Guide(description: """
        The best flight window copied exactly from FACTS.bestWindow, prefixed \
        with "Best window". If FACTS.bestWindow is null, write "No clear window \
        in the next" followed by FACTS.windowHorizonHours and "hours".
        """)
    var suggestedWindow: String
}

// MARK: - Generator

struct PCCBriefingGenerator: BriefingGenerating {

    static let instructions = """
        You write pre-flight weather briefings for a drone pilot, shown on an \
        Apple Watch. The prompt contains FACTS as JSON from a deterministic \
        safety engine. The engine has already decided; you only put its facts \
        into plain English.

        Rules:
        - Tone: calm, factual, pilot-to-pilot. No hype, no exclamation marks, \
        no emojis.
        - The verdict in FACTS is final. State it exactly as given (GO, \
        CAUTION or NO-GO). Never soften, upgrade, or contradict it, and never \
        use the words GO, CAUTION or NO-GO for anything else.
        - Use only numbers that appear in FACTS, copied character for \
        character, written as digits. Never calculate, round, convert units, \
        estimate, or add numbers of your own.
        - Explain the verdict using FACTS.primaryFactor. Keep the detail to \
        one or two sentences.
        - Do not give advice about airspace, regulations, or anything not in \
        FACTS.
        """

    func availability() async -> BriefingModelAvailability {
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            // Quota is independent of availability: a model can be
            // available with the pilot's daily budget already spent.
            return model.quotaUsage.isLimitReached ? .unavailable(.quotaReached) : .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .systemNotReady:    return .unavailable(.systemNotReady)
            @unknown default:        return .unavailable(.unknown)
            }
        @unknown default:
            return .unavailable(.unknown)
        }
    }

    func generate(from facts: BriefingFacts) async throws -> BriefingDraft {
        // A fresh session per briefing: no transcript carries facts from
        // one aircraft or snapshot into the next.
        let session = LanguageModelSession(
            model: PrivateCloudComputeLanguageModel(),
            instructions: Self.instructions)

        // Facts go in as serialized JSON — structured data, never prose.
        let json = try facts.jsonString()
        let prompt = "FACTS:\n" + json
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedBriefing.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200))

        let content = response.content
        return BriefingDraft(headline: content.headline,
                             detail: content.detail,
                             window: content.suggestedWindow)
    }
}
