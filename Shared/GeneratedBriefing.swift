//
//  GeneratedBriefing.swift
//  DroneCast — Shared (watch app + iPhone app; not the widget or tests)
//
//  Guided-generation schemas for Apple's Foundation Models: the full
//  briefing for Private Cloud Compute on the watch, and the detail
//  sentence alone for the iPhone's smaller on-device model.
//  Descriptions mirror BriefingPrompt's *Guide strings.
//

import FoundationModels

@Generable(description: "A short pre-flight weather briefing for a drone pilot.")
struct GeneratedBriefing {
    @Guide(description: """
        At most 40 characters, for a watch complication: the verdict from FACTS \
        exactly as written (GO, CAUTION or NO-GO), then " · ", then a reason of \
        a few words like FACTS.headlineReason. Never copy FACTS.primaryFactor here.
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

@Generable(description: "The explanation sentence of a pre-flight weather briefing for a drone pilot.")
struct GeneratedDetail {
    @Guide(description: """
        One or two calm, plain sentences explaining the verdict for the aircraft \
        in FACTS. Quote numbers exactly as they appear in FACTS, as digits.
        """)
    var detail: String
}
