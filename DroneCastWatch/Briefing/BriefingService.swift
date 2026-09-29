//
//  BriefingService.swift
//  DroneCast — Briefing layer (compiled into app and test targets)
//
//  Facts in, briefing out. The pipeline, in order:
//    user toggle → cache → generator availability → generate (with a
//    timeout) → hallucination guard → cache → return.
//  Every exit that isn't a guard-approved model answer returns the
//  deterministic template instead, so callers always get a briefing.
//
//  The model sits behind `BriefingGenerating` so tests (and builds without
//  the Private Cloud Compute entitlement) never need a real one.
//

import Foundation
import os

/// The seam between DroneCast and any language model.
protocol BriefingGenerating: Sendable {
    /// Checked before every generation request.
    func availability() async -> BriefingModelAvailability
    /// Turn engine facts into text. Output is untrusted until the guard
    /// has checked it.
    func generate(from facts: BriefingFacts) async throws -> BriefingDraft
}

enum BriefingError: Error, Equatable {
    case timedOut
}

@MainActor
final class BriefingService {

    private let generator: (any BriefingGenerating)?
    private let defaults: UserDefaults
    private let timeout: Duration

    private static let log = Logger(subsystem: "com.sguzyayev.dronecast", category: "Briefing")

    /// - Parameter generator: nil when the model path is compiled out; the
    ///   service then always answers with the template.
    init(generator: (any BriefingGenerating)?,
         defaults: UserDefaults = BriefingStore.sharedDefaults,
         timeout: Duration = .seconds(12)) {
        self.generator = generator
        self.defaults = defaults
        self.timeout = timeout
    }

    // MARK: Immediate (no model)

    /// What to show the instant the facts change, before any model call:
    /// the cached briefing when it describes exactly these facts, the
    /// template otherwise. Always persisted, so the complication has text.
    func immediateBriefing(for facts: BriefingFacts,
                           snapshotTimestamp: Date,
                           aiEnabled: Bool) -> Briefing {
        if aiEnabled, var entry = BriefingStore.entry(forProfile: facts.aircraftID, in: defaults),
           entry.facts == facts {
            entry.briefing.snapshotTimestamp = snapshotTimestamp
            BriefingStore.save(entry, to: defaults)
            return entry.briefing
        }
        let reason: BriefingFallbackReason? = aiEnabled ? nil : .disabledByUser
        let briefing = BriefingTemplate.briefing(
            for: facts, snapshotTimestamp: snapshotTimestamp, reason: reason)
        store(briefing, facts: facts, modelSettled: false)
        return briefing
    }

    // MARK: Full pipeline

    func briefing(for facts: BriefingFacts,
                  snapshotTimestamp: Date,
                  aiEnabled: Bool) async -> Briefing {
        guard aiEnabled else {
            return fallback(facts, snapshotTimestamp, .disabledByUser, settled: false)
        }

        // Only regenerate when the facts actually changed.
        if var entry = BriefingStore.entry(forProfile: facts.aircraftID, in: defaults),
           entry.facts == facts, entry.modelSettled {
            entry.briefing.snapshotTimestamp = snapshotTimestamp
            BriefingStore.save(entry, to: defaults)
            return entry.briefing
        }

        guard let generator else {
            return fallback(facts, snapshotTimestamp, .modelUnavailable(.notConfigured), settled: false)
        }

        switch await generator.availability() {
        case .available:
            break
        case .unavailable(let reason):
            Self.log.info("Model unavailable: \(reason.rawValue, privacy: .public)")
            return fallback(facts, snapshotTimestamp, .modelUnavailable(reason), settled: false)
        }

        let draft: BriefingDraft
        do {
            draft = try await Self.withTimeout(timeout) {
                try await generator.generate(from: facts)
            }
        } catch BriefingError.timedOut {
            Self.log.error("Model timed out")
            return fallback(facts, snapshotTimestamp, .timedOut, settled: false)
        } catch {
            Self.log.error("Model failed: \(error.localizedDescription, privacy: .public)")
            return fallback(facts, snapshotTimestamp,
                            .generationFailed(error.localizedDescription), settled: false)
        }

        let violations = HallucinationGuard.violations(in: draft, for: facts)
        guard violations.isEmpty else {
            Self.log.error("Guard rejected model output: \(String(describing: violations), privacy: .public)")
            // Settled: the same facts would likely fail the same way, and
            // each retry spends the pilot's quota.
            return fallback(facts, snapshotTimestamp, .rejectedByGuard(violations), settled: true)
        }

        let briefing = Briefing(
            headline: draft.headline.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: draft.detail.trimmingCharacters(in: .whitespacesAndNewlines),
            window: draft.window.trimmingCharacters(in: .whitespacesAndNewlines),
            source: .ai,
            fallbackReason: nil,
            verdict: facts.verdict,
            profileID: facts.aircraftID,
            snapshotTimestamp: snapshotTimestamp)
        store(briefing, facts: facts, modelSettled: true)
        return briefing
    }

    // MARK: Helpers

    /// Transient failures (unavailable, timeout, network) stay unsettled so
    /// the next foreground refresh with the same facts tries again.
    private func fallback(_ facts: BriefingFacts,
                          _ snapshotTimestamp: Date,
                          _ reason: BriefingFallbackReason,
                          settled: Bool) -> Briefing {
        let briefing = BriefingTemplate.briefing(
            for: facts, snapshotTimestamp: snapshotTimestamp, reason: reason)
        store(briefing, facts: facts, modelSettled: settled)
        return briefing
    }

    private func store(_ briefing: Briefing, facts: BriefingFacts, modelSettled: Bool) {
        BriefingStore.save(
            BriefingCacheEntry(facts: facts, briefing: briefing, modelSettled: modelSettled),
            to: defaults)
    }

    /// Races `operation` against a deadline; the loser is cancelled.
    static func withTimeout<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw BriefingError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw BriefingError.timedOut }
            return first
        }
    }
}
