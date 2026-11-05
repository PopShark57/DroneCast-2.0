//
//  PCCBriefingGenerator.swift
//  DroneCast — Services layer (app target only)
//
//  Apple's Private Cloud Compute model, the only Apple model a watch can
//  use: watchOS 27 has NO on-device language model (SystemLanguageModel is
//  unavailable on watchOS), and the watch does not borrow the iPhone's.
//  Using PCC needs the managed Private Cloud Compute entitlement, which
//  Apple grants only to App Store Small Business Program members — i.e.
//  not to free personal teams. So it ships switched off.
//
//  Free-team builds get AI briefings from the other two links in the
//  chain instead (see FlightStore): Claude over the Anthropic API, then
//  the iPhone companion's on-device model.
//
//  To enable after qualifying:
//    1. Request the Private Cloud Compute entitlement
//       (developer.apple.com/private-cloud-compute) and add it to the
//       watch app target in Signing & Capabilities.
//    2. Flip BriefingConfig.useCloudModel to true.
//

import Foundation
import FoundationModels

enum BriefingConfig {
    static let useCloudModel = false
}

struct PCCBriefingGenerator: BriefingGenerating {

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
            instructions: BriefingPrompt.instructions)

        let response = try await session.respond(
            to: BriefingPrompt.prompt(factsJSON: try facts.jsonString()),
            generating: GeneratedBriefing.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200))

        let content = response.content
        return BriefingDraft(headline: content.headline,
                             detail: content.detail,
                             window: content.suggestedWindow,
                             provider: .privateCloudCompute)
    }
}
