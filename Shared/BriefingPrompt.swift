//
//  BriefingPrompt.swift
//  DroneCast — Shared (watch app, iPhone app, tests)
//
//  The one prompt every language model gets, whichever one writes the
//  briefing: Claude over the Anthropic API, the iPhone's on-device Apple
//  Intelligence model, or Private Cloud Compute. Keeping it in one place
//  means the hallucination guard on the watch is checking all of them
//  against the same rules.
//
//  Foundation only, so the iPhone app can use it without the watch's
//  domain types: the iPhone receives the facts as a JSON string and never
//  decodes them.
//

import Foundation

enum BriefingPrompt {

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
        - Explain the verdict using FACTS.primaryFactor, and include every \
        number it contains plus the score from FACTS.score. Keep the detail \
        to one or two sentences.
        - Write for the pilot: never mention FACTS, JSON, or field names.
        - Do not give advice about airspace, regulations, or anything not in \
        FACTS.
        """

    // Field descriptions, shared by the Claude JSON schema. The
    // @Generable struct in GeneratedBriefing.swift repeats them as literals
    // because the @Guide macro wants literals; keep the two in step.

    static let headlineGuide = """
        At most 40 characters, for a watch complication: the verdict from FACTS \
        exactly as written (GO, CAUTION or NO-GO), then " · ", then a reason of \
        a few words like FACTS.headlineReason. Never copy FACTS.primaryFactor here.
        """

    static let detailGuide = """
        One or two calm, plain sentences explaining the verdict for the aircraft \
        in FACTS. Quote numbers exactly as they appear in FACTS, as digits.
        """

    static let windowGuide = """
        The best flight window copied exactly from FACTS.bestWindow, prefixed \
        with "Best window". If FACTS.bestWindow is null, write "No clear window \
        in the next" followed by FACTS.windowHorizonHours and "hours".
        """

    /// Shorter, example-led instructions for the iPhone's ~3B on-device
    /// model, which follows the full rule list above poorly (it echoes
    /// field names, prefixes numbers with "#", and runs long).
    static let onDeviceInstructions = """
        You explain a drone flight verdict to the pilot in one or two short, \
        plain sentences. The verdict and numbers come from FACTS and are final.

        - Use the numbers from FACTS exactly, as digits, with their units \
        (mph, %). Always include the score.
        - Say why, using FACTS.primaryFactor.
        - Do not repeat the verdict word, and do not mention FACTS or field names.

        Example: Gusts of 14 mph sit well inside the 25 mph limit for the DJI \
        Air 3S, and rain chance is 10 %, for a score of 92.
        """

    /// Prompt for the iPhone's small on-device model, which only writes
    /// the explanation sentence: the watch fills in the headline and the
    /// window from the engine, because a ~3B model keeps overrunning the
    /// 40-character headline and inventing windows.
    static func detailOnlyPrompt(factsJSON: String) -> String {
        prompt(factsJSON: factsJSON) + "\n\nWrite only the detail."
    }

    /// Facts go in as serialized JSON — structured data, never prose.
    static func prompt(factsJSON: String) -> String {
        "FACTS:\n" + factsJSON
    }
}

/// The watch ⇄ iPhone message format (WatchConnectivity dictionaries).
/// Values are plain strings so both sides stay property-list safe.
enum BriefingRelay {
    /// Watch → iPhone: the facts JSON string.
    static let factsKey = "facts"

    /// iPhone → watch on success: the detail sentence only. The watch
    /// supplies the headline and window from the engine.
    static let detailKey = "detail"

    /// iPhone → watch on failure: one of the codes below, plus a message.
    static let errorKey = "error"
    static let messageKey = "message"

    enum ErrorCode: String, Sendable {
        /// The iPhone's model isn't available (not eligible, Apple
        /// Intelligence off, model still downloading).
        case modelUnavailable
        /// The model was available but generation threw.
        case generationFailed
        /// The watch sent something the iPhone couldn't read.
        case badRequest
    }
}
