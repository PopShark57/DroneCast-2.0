//
//  CanIFlyIntent.swift
//  DroneCast — App Intents (app target)
//
//  "Can I fly?" for Siri on the watch. Answers from the persisted verdict
//  and the cached briefing for the selected aircraft — no weather fetch,
//  no language-model call — so it responds instantly and says so when the
//  data is stale instead of guessing.
//

import AppIntents

struct CanIFlyIntent: AppIntent {
    static let title: LocalizedStringResource = "Can I fly?"
    static let description: IntentDescription? = IntentDescription(
        "Hear the DroneCast flight briefing for your selected aircraft.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = BriefingAnswer.text(state: SharedStore.load(),
                                         cache: BriefingStore.loadAll())
        return .result(value: answer, dialog: "\(answer)")
    }
}

struct DroneCastShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CanIFlyIntent(),
            phrases: [
                "Can I fly with \(.applicationName)",
                "Can I fly my drone with \(.applicationName)",
                "\(.applicationName) briefing",
            ],
            shortTitle: "Can I fly?",
            systemImageName: "airplane")
    }
}
