//
//  ChainedBriefingGenerator.swift
//  DroneCast — Briefing layer (compiled into app, widget, and test targets)
//
//  Tries several language models in order and returns the first answer
//  that passes the hallucination guard. On a free personal team the chain
//  is Claude (watch → Anthropic API) then the iPhone's on-device model;
//  BriefingService still falls back to the template when every link is
//  unavailable, fails, or writes something the guard rejects.
//

import Foundation

enum ChainedBriefingError: Error, Equatable {
    /// No link reported itself available by the time generate ran.
    case noLinkAvailable
}

struct ChainedBriefingGenerator: BriefingGenerating {

    let links: [any BriefingGenerating]

    init(_ links: [any BriefingGenerating]) {
        self.links = links
    }

    /// Available when any link is. When none is, reports the most useful
    /// reason for the settings screen: a link that's set up but can't be
    /// reached right now beats one that was never configured.
    func availability() async -> BriefingModelAvailability {
        var reasons: [BriefingModelAvailability.Reason] = []
        for link in links {
            switch await link.availability() {
            case .available:              return .available
            case .unavailable(let reason): reasons.append(reason)
            }
        }
        return .unavailable(Self.mostUseful(reasons))
    }

    func generate(from facts: BriefingFacts) async throws -> BriefingDraft {
        var lastError: any Error = ChainedBriefingError.noLinkAvailable
        var rejected: BriefingDraft?

        for link in links {
            try Task.checkCancellation()
            guard await link.availability() == .available else { continue }
            do {
                let draft = try await link.generate(from: facts)
                // Checked here as well as in BriefingService so a bad
                // answer from one model gives the next model a turn.
                if HallucinationGuard.violations(in: draft, for: facts).isEmpty {
                    return draft
                }
                rejected = rejected ?? draft
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        // Every model's text failed the guard: hand back the first one so
        // the service records the rejection (and stops re-asking).
        if let rejected { return rejected }
        throw lastError
    }

    /// Reasons that mean "not set up in this build" — the least
    /// interesting thing to tell the pilot when something else is set up.
    private static let notSetUp: Set<BriefingModelAvailability.Reason> =
        [.notConfigured, .missingAPIKey, .phoneAppMissing]

    static func mostUseful(_ reasons: [BriefingModelAvailability.Reason])
        -> BriefingModelAvailability.Reason {
        reasons.first { !notSetUp.contains($0) } ?? reasons.first ?? .notConfigured
    }
}
