//
//  OnDeviceBriefingWriter.swift
//  DroneCast iPhone companion
//
//  Runs Apple's on-device model (SystemLanguageModel) on the briefing
//  facts the watch sends. No entitlement and no network: works on a free
//  personal team, on an Apple Intelligence iPhone with Apple Intelligence
//  turned on in Settings.
//
//  The facts arrive as a JSON string and go straight into the prompt —
//  the iPhone never interprets them, and the watch's hallucination guard
//  checks whatever comes back.
//

import Foundation
import FoundationModels

enum OnDeviceBriefingWriter {

    enum WriterError: Error, LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return why
            }
        }
    }

    /// Nil when the model is ready; otherwise why not, in plain words.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This iPhone doesn't support Apple Intelligence (needs iPhone 15 Pro or newer)."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is off. Turn it on in Settings → Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "The Apple Intelligence model is still downloading. Keep the iPhone on Wi-Fi and power."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    /// The explanation sentence only — see BriefingPrompt.detailOnlyPrompt.
    static func writeDetail(factsJSON: String) async throws -> String {
        if let why = unavailableReason { throw WriterError.unavailable(why) }

        // A fresh session per briefing: nothing carries over between
        // aircraft or snapshots.
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: BriefingPrompt.onDeviceInstructions)

        let response = try await session.respond(
            to: BriefingPrompt.detailOnlyPrompt(factsJSON: factsJSON),
            generating: GeneratedDetail.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 150))
        return response.content.detail
    }

    /// Representative facts for the in-app "Test" button, in the same
    /// shape the watch sends.
    static let sampleFactsJSON = """
        {"aircraftID":"neo2","aircraftName":"DJI Neo 2","bestWindow":"2 PM – 5 PM",\
        "dataSource":"Open-Meteo","headlineReason":"score 68","otherFactors":[],\
        "precipitation":{"chanceLimitPercent":"30","chancePercent":"5","fallingNow":false},\
        "primaryFactor":"Gusts 19 mph nearing 20 mph limit","score":68,"temperatureF":"72",\
        "verdict":"CAUTION","visibilityMiles":"10","wind":{"gustLimitMph":"20",\
        "gustLimitSetBy":"pilot threshold","gustMph":"19","sustainedMph":"4"},\
        "windowHorizonHours":"12"}
        """
}
