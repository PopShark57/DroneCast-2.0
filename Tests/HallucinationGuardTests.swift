//
//  HallucinationGuardTests.swift
//  DroneCastTests
//
//  Model output that invents, rounds, drops, or flips anything must be
//  rejected — and the service must then fall back to the template.
//

import Testing
import Foundation

struct HallucinationGuardTests {

    /// A well-behaved "model" answer for the CAUTION scenario (Neo 2, 19 mph
    /// gusts against a 20 mph limit).
    private func goodCautionDraft(_ facts: BriefingFacts) -> BriefingDraft {
        BriefingDraft(
            headline: "CAUTION · gusts near limit",
            detail: "Gusts of 19 mph are close to the 20 mph limit for the DJI Neo 2. "
                + "Score \(facts.score).",
            window: "Best window 2 PM – 5 PM")
    }

    @Test func acceptsFaithfulRewording() {
        let facts = Fixture.facts(.caution)
        #expect(HallucinationGuard.violations(in: goodCautionDraft(facts), for: facts) == [])
    }

    // MARK: Numbers

    @Test func rejectsAWrongNumber() {
        let facts = Fixture.facts(.caution)
        var draft = goodCautionDraft(facts)
        draft.detail = draft.detail.replacingOccurrences(of: "19 mph", with: "21 mph")
        let violations = HallucinationGuard.violations(in: draft, for: facts)
        #expect(violations.contains(.unexpectedNumber("21")))
        #expect(violations.contains(.missingRequiredNumber("19")))
    }

    @Test func rejectsARoundedNumber() {
        let facts = Fixture.facts(.noGoGate)   // Neo limit is 17.9
        let draft = BriefingDraft(
            headline: "NO-GO · gusts over limit",
            detail: "Gusts of 19 mph exceed the DJI Neo's 18 mph limit.",
            window: "Best window 2 PM – 5 PM")
        let violations = HallucinationGuard.violations(in: draft, for: facts)
        #expect(violations.contains(.unexpectedNumber("18")))
        #expect(violations.contains(.missingRequiredNumber("17.9")))
    }

    @Test func rejectsAMissingNumber() {
        let facts = Fixture.facts(.caution)
        let draft = BriefingDraft(
            headline: "CAUTION · gusts near limit",
            detail: "Gusts are close to the limit for the DJI Neo 2.",
            window: "Best window 2 PM – 5 PM")
        let violations = HallucinationGuard.violations(in: draft, for: facts)
        #expect(violations.contains(.missingRequiredNumber("19")))
        #expect(violations.contains(.missingRequiredNumber("20")))
    }

    @Test func rejectsANumberSpelledOut() {
        let facts = Fixture.facts(.caution)
        var draft = goodCautionDraft(facts)
        draft.detail += " Expect twenty minutes of battery."
        #expect(HallucinationGuard.violations(in: draft, for: facts)
            .contains(.spelledOutNumber("twenty")))
    }

    @Test func rejectsAnInventedWindow() {
        let facts = Fixture.facts(.caution, window: nil)
        var draft = goodCautionDraft(facts)
        draft.window = "Best window 6 PM – 8 PM"
        let violations = HallucinationGuard.violations(in: draft, for: facts)
        #expect(violations.contains(.unexpectedNumber("6")))
        #expect(violations.contains(.unexpectedNumber("8")))
    }

    // MARK: Verdict

    @Test func rejectsAFlippedVerdict() {
        let facts = Fixture.facts(.noGoGate)
        let draft = BriefingDraft(
            headline: "GO · light winds",
            detail: "Gusts 19 mph against a 17.9 mph limit on the DJI Neo.",
            window: "Best window 2 PM – 5 PM")
        let violations = HallucinationGuard.violations(in: draft, for: facts)
        #expect(violations.contains(.verdictMissing))
        #expect(violations.contains(.verdictContradicted(.go)))
    }

    @Test func rejectsASoftenedVerdict() {
        // Right label in the headline, wrong message in the detail.
        let facts = Fixture.facts(.noGoGate)
        let draft = BriefingDraft(
            headline: "NO-GO · gusts over limit",
            detail: "Gusts 19 mph against a 17.9 mph limit, but it's fine to fly low.",
            window: "Best window 2 PM – 5 PM")
        #expect(HallucinationGuard.violations(in: draft, for: facts)
            .contains(.verdictContradicted(.go)))
    }

    @Test func rejectsCautionWordingOnAGoDay() {
        let facts = Fixture.facts(.go)
        let draft = BriefingDraft(
            headline: "GO · within your limits",
            detail: "Marginal breeze, score \(facts.score).",
            window: "Best window 2 PM – 5 PM")
        #expect(HallucinationGuard.violations(in: draft, for: facts)
            .contains(.verdictContradicted(.caution)))
    }

    @Test func verdictPhraseDetection() {
        #expect(HallucinationGuard.verdicts(mentionedIn: "NO-GO today") == [.noGo])
        #expect(HallucinationGuard.verdicts(mentionedIn: "No go.") == [.noGo])
        #expect(HallucinationGuard.verdicts(mentionedIn: "It is not safe to fly.") == [.noGo])
        #expect(HallucinationGuard.verdicts(mentionedIn: "Don’t fly the Neo.") == [.noGo])
        #expect(HallucinationGuard.verdicts(mentionedIn: "GO · clear") == [.go])
        #expect(HallucinationGuard.verdicts(mentionedIn: "Safe to fly") == [.go])
        #expect(HallucinationGuard.verdicts(mentionedIn: "CAUTION: marginal") == [.caution])
        #expect(HallucinationGuard.verdicts(mentionedIn: "Goggles N3 may fog").isEmpty)
    }

    // MARK: Shape

    @Test func rejectsAnOverlongHeadline() {
        let facts = Fixture.facts(.caution)
        var draft = goodCautionDraft(facts)
        draft.headline = "CAUTION · gusts are getting close to the limit today"
        #expect(HallucinationGuard.violations(in: draft, for: facts)
            .contains(.headlineTooLong(draft.headline.count)))
    }

    @Test func rejectsMoreThanTwoSentences() {
        let facts = Fixture.facts(.caution)
        var draft = goodCautionDraft(facts)
        draft.detail += " Stay low. Land early."
        #expect(HallucinationGuard.violations(in: draft, for: facts)
            .contains(.tooManySentences(4)))
    }

    @Test func decimalsAreNotSentenceBreaks() {
        #expect(HallucinationGuard.sentenceCount("Limit 17.9 mph. Gusts 19 mph.") == 2)
    }

    @Test func rejectsEmptyFields() {
        let facts = Fixture.facts(.caution)
        var draft = goodCautionDraft(facts)
        draft.window = "  "
        #expect(HallucinationGuard.violations(in: draft, for: facts).contains(.emptyField("window")))
    }
}

// MARK: - The service must fall back on every guard failure

@MainActor
struct GuardFallbackTests {

    private func briefing(for facts: BriefingFacts,
                          modelWrites draft: BriefingDraft) async -> Briefing {
        let service = BriefingService(
            generator: MockGenerator(output: { _ in draft }),
            defaults: Fixture.defaults())
        return await service.briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
    }

    private func expectTemplate(_ briefing: Briefing, for facts: BriefingFacts,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        let template = BriefingTemplate.draft(for: facts)
        #expect(briefing.source == .template, sourceLocation: sourceLocation)
        #expect(briefing.headline == template.headline, sourceLocation: sourceLocation)
        #expect(briefing.detail == template.detail, sourceLocation: sourceLocation)
        #expect(briefing.window == template.window, sourceLocation: sourceLocation)
    }

    @Test func wrongNumberFallsBackToTemplate() async {
        let facts = Fixture.facts(.caution)
        let briefing = await briefing(for: facts, modelWrites: BriefingDraft(
            headline: "CAUTION · gusts near limit",
            detail: "Gusts of 21 mph are close to the 20 mph limit.",
            window: "Best window 2 PM – 5 PM"))
        expectTemplate(briefing, for: facts)
        guard case .rejectedByGuard(let violations)? = briefing.fallbackReason else {
            Issue.record("expected a guard rejection, got \(String(describing: briefing.fallbackReason))")
            return
        }
        #expect(violations.contains(.unexpectedNumber("21")))
    }

    @Test func missingNumberFallsBackToTemplate() async {
        let facts = Fixture.facts(.caution)
        let briefing = await briefing(for: facts, modelWrites: BriefingDraft(
            headline: "CAUTION · gusts near limit",
            detail: "Gusts are close to your limit.",
            window: "Best window 2 PM – 5 PM"))
        expectTemplate(briefing, for: facts)
        guard case .rejectedByGuard(let violations)? = briefing.fallbackReason else {
            Issue.record("expected a guard rejection")
            return
        }
        #expect(violations.contains(.missingRequiredNumber("19")))
    }

    @Test func flippedVerdictFallsBackToTemplate() async {
        let facts = Fixture.facts(.noGoGate)
        let briefing = await briefing(for: facts, modelWrites: BriefingDraft(
            headline: "GO · light winds",
            detail: "Gusts 19 mph against a 17.9 mph limit.",
            window: "Best window 2 PM – 5 PM"))
        expectTemplate(briefing, for: facts)
        #expect(briefing.verdict == .noGo)
        guard case .rejectedByGuard(let violations)? = briefing.fallbackReason else {
            Issue.record("expected a guard rejection")
            return
        }
        #expect(violations.contains(.verdictContradicted(.go)))
    }
}
