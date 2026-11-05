//
//  WatchRelay.swift
//  DroneCast iPhone companion
//
//  Answers the watch's briefing requests. The watch sends facts with
//  sendMessage(_:replyHandler:); iOS launches this app in the background
//  if needed, we run the on-device model and reply with the detail
//  sentence (or an error code the watch maps to the template).
//

import Foundation
import Observation
import WatchConnectivity

/// What the companion screen shows. Main-actor only.
@MainActor @Observable
final class RelayStatus {
    static let shared = RelayStatus()

    var isPaired = false
    var isWatchAppInstalled = false
    var requestsServed = 0
    var lastDetail: String?
    var lastError: String?
    var lastRequestAt: Date?
}

final class WatchRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchRelay()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    // MARK: Session lifecycle (iOS)

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: (any Error)?) {
        publishPairing(session)
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        publishPairing(session)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Switching to another watch: activate again for the new one.
        session.activate()
    }

    private func publishPairing(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            RelayStatus.shared.isPaired = paired
            RelayStatus.shared.isWatchAppInstalled = installed
        }
    }

    // MARK: Requests

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = Reply(replyHandler)
        guard let facts = message[BriefingRelay.factsKey] as? String else {
            reply.send([BriefingRelay.errorKey: BriefingRelay.ErrorCode.badRequest.rawValue,
                        BriefingRelay.messageKey: "No facts in request"])
            return
        }
        Task {
            let answer = await Self.answer(factsJSON: facts)
            reply.send(answer)
            await Self.record(answer)
        }
    }

    /// Plain [String: String] so it can cross into the reply closure.
    static func answer(factsJSON: String) async -> [String: String] {
        if let why = OnDeviceBriefingWriter.unavailableReason {
            return [BriefingRelay.errorKey: BriefingRelay.ErrorCode.modelUnavailable.rawValue,
                    BriefingRelay.messageKey: why]
        }
        do {
            let detail = try await OnDeviceBriefingWriter.writeDetail(factsJSON: factsJSON)
            return [BriefingRelay.detailKey: detail]
        } catch {
            return [BriefingRelay.errorKey: BriefingRelay.ErrorCode.generationFailed.rawValue,
                    BriefingRelay.messageKey: error.localizedDescription]
        }
    }

    @MainActor
    private static func record(_ answer: [String: String]) {
        let status = RelayStatus.shared
        status.requestsServed += 1
        status.lastRequestAt = .now
        status.lastDetail = answer[BriefingRelay.detailKey]
        status.lastError = answer[BriefingRelay.messageKey]
    }
}

/// WatchConnectivity's reply handler isn't Sendable, but it is documented
/// as safe to call once from any thread — which is all we do.
private struct Reply: @unchecked Sendable {
    let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ dictionary: [String: String]) { handler(dictionary) }
}
