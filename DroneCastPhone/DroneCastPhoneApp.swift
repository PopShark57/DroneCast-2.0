//
//  DroneCastPhoneApp.swift
//  DroneCast iPhone companion
//
//  A small helper app. Its job is to lend the watch the iPhone's on-device
//  Apple Intelligence model for AI briefings; flight scoring stays on the
//  watch. It doesn't need to be open — iOS wakes it in the background when
//  the watch asks for a briefing.
//

import SwiftUI

@main
struct DroneCastPhoneApp: App {

    init() {
        // Must happen at every launch, including background launches iOS
        // makes to deliver a watch message.
        WatchRelay.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            CompanionView()
        }
    }
}

struct CompanionView: View {
    @State private var status = RelayStatus.shared
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            List {
                Section("Apple Intelligence") {
                    if let why = OnDeviceBriefingWriter.unavailableReason {
                        Label(why, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Label("On-device model ready", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    }
                    Button {
                        Task { await runTest() }
                    } label: {
                        Label(isTesting ? "Writing…" : "Test a sample briefing", systemImage: "sparkles")
                    }
                    .disabled(isTesting)
                    if let testResult {
                        Text(testResult).font(.callout)
                    }
                }

                Section("Apple Watch") {
                    LabeledContent("Paired", value: status.isPaired ? "Yes" : "No")
                    LabeledContent("DroneCast on watch", value: status.isWatchAppInstalled ? "Installed" : "Not installed")
                    LabeledContent("Briefings written", value: "\(status.requestsServed)")
                    if let at = status.lastRequestAt {
                        LabeledContent("Last request", value: at.formatted(date: .omitted, time: .shortened))
                    }
                    if let detail = status.lastDetail {
                        Text(detail).font(.callout)
                    } else if let error = status.lastError {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Your watch asks Claude first when a Claude API key is set, and this iPhone "
                         + "when it isn't (or Claude can't be reached). Either way the watch's "
                         + "scoring engine decides GO / CAUTION / NO-GO, and any AI text that "
                         + "changes a number or the verdict is thrown away for the template.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("DroneCast")
        }
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        let answer = await WatchRelay.answer(factsJSON: OnDeviceBriefingWriter.sampleFactsJSON)
        if let detail = answer[BriefingRelay.detailKey] {
            testResult = detail
        } else {
            testResult = answer[BriefingRelay.messageKey] ?? "Failed"
        }
    }
}
