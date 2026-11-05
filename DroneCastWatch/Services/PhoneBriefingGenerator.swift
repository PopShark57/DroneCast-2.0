//
//  PhoneBriefingGenerator.swift
//  DroneCast — Services layer (app target only)
//
//  Borrows the paired iPhone's on-device Apple Intelligence model. The
//  watch has no model of its own and watchOS won't use the iPhone's
//  automatically, so DroneCast does it explicitly: the facts JSON goes to
//  the DroneCast iPhone app over WatchConnectivity, the iPhone runs
//  SystemLanguageModel to write the explanation sentence, and it comes
//  back here — where the hallucination guard checks it like any other
//  model's output. The headline and window are the engine's own wording.
//
//  No entitlement, no account, no cost; needs an Apple Intelligence
//  iPhone (15 Pro or newer) with Apple Intelligence turned on, in
//  Bluetooth or Wi-Fi range. iOS wakes the iPhone app in the background
//  for the request, so it doesn't need to be open.
//

import Foundation
import WatchConnectivity

/// Owns the watch's WCSession. Activate once at launch; properties are
/// only meaningful after activation completes.
final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneLink()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: (any Error)?) {}

    var availability: BriefingModelAvailability {
        guard WCSession.isSupported() else { return .unavailable(.phoneAppMissing) }
        let session = WCSession.default
        guard session.activationState == .activated else { return .unavailable(.phoneUnreachable) }
        guard session.isCompanionAppInstalled else { return .unavailable(.phoneAppMissing) }
        guard session.isReachable else { return .unavailable(.phoneUnreachable) }
        return .available
    }
}

enum PhoneBriefingError: Error, Equatable, LocalizedError {
    /// The iPhone answered with an error code from BriefingRelay.ErrorCode.
    case phone(code: String, message: String)
    case badReply

    var errorDescription: String? {
        switch self {
        case .phone(_, let message): return "iPhone: \(message)"
        case .badReply:              return "Unreadable reply from iPhone"
        }
    }
}

struct PhoneBriefingGenerator: BriefingGenerating {

    let link: PhoneLink

    init(link: PhoneLink = .shared) {
        self.link = link
        link.activate()
    }

    func availability() async -> BriefingModelAvailability {
        link.availability
    }

    func generate(from facts: BriefingFacts) async throws -> BriefingDraft {
        let message: [String: Any] = [BriefingRelay.factsKey: try facts.jsonString()]
        return try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(message, replyHandler: { reply in
                continuation.resume(with: Self.draft(from: reply, facts: facts))
            }, errorHandler: { error in
                continuation.resume(throwing: error)
            })
        }
    }

    /// The iPhone writes the detail sentence; the headline and window come
    /// from the engine, exactly as the template words them.
    static func draft(from reply: [String: Any],
                      facts: BriefingFacts) -> Result<BriefingDraft, any Error> {
        if let code = reply[BriefingRelay.errorKey] as? String {
            let message = reply[BriefingRelay.messageKey] as? String ?? code
            return .failure(PhoneBriefingError.phone(code: code, message: message))
        }
        guard let detail = reply[BriefingRelay.detailKey] as? String else {
            return .failure(PhoneBriefingError.badReply)
        }
        return .success(BriefingDraft(headline: BriefingTemplate.headline(for: facts),
                                      detail: detail,
                                      window: BriefingTemplate.window(for: facts),
                                      provider: .iPhone))
    }
}
