//
//  HallucinationGuard.swift
//  DroneCast — Briefing layer (compiled into app, widget, and test targets)
//
//  Runs on every piece of model output before anyone sees it. The model
//  only rephrases engine facts, so anything it adds is by definition
//  wrong: a number that isn't in the facts, a required number it dropped,
//  or verdict wording that doesn't match the engine. Any violation throws
//  the whole draft away in favour of the template.
//
//  Deliberately strict — a false positive costs a template briefing,
//  a false negative could tell a pilot the wrong thing.
//

import Foundation

enum GuardViolation: Codable, Equatable, Sendable {
    case emptyField(String)
    case headlineTooLong(Int)
    case tooManySentences(Int)
    /// A numeric token that appears nowhere in the facts (invented, rounded,
    /// converted or computed).
    case unexpectedNumber(String)
    /// "twenty", "a dozen" … — numbers written as words dodge digit checks.
    case spelledOutNumber(String)
    /// A number behind the binding factor (or the score) left out.
    case missingRequiredNumber(String)
    /// The headline doesn't state the engine's verdict.
    case verdictMissing
    /// Wording that implies a different verdict appears anywhere.
    case verdictContradicted(Verdict)
}

enum HallucinationGuard {

    static let maxHeadlineLength = 40
    static let maxDetailSentences = 2

    static func accepts(_ draft: BriefingDraft, for facts: BriefingFacts) -> Bool {
        violations(in: draft, for: facts).isEmpty
    }

    static func violations(in draft: BriefingDraft, for facts: BriefingFacts) -> [GuardViolation] {
        var found: [GuardViolation] = []

        let headline = draft.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = draft.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = draft.window.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = [headline, detail, window]
        let allText = fields.joined(separator: "\n")

        // ---- Shape ------------------------------------------------------
        for (name, value) in [("headline", headline), ("detail", detail), ("window", window)]
        where value.isEmpty {
            found.append(.emptyField(name))
        }
        if headline.count > maxHeadlineLength {
            found.append(.headlineTooLong(headline.count))
        }
        let sentences = sentenceCount(detail)
        if sentences > maxDetailSentences {
            found.append(.tooManySentences(sentences))
        }

        // ---- Numbers ----------------------------------------------------
        let allowed = facts.allowedNumbers
        let written = fields.flatMap(BriefingNumbers.extract)
        var reported = Set<String>()
        for number in written where !allowed.contains(number) {
            if reported.insert(number).inserted {
                found.append(.unexpectedNumber(number))
            }
        }

        let factWords = Set(facts.quotableText.flatMap { numberWords(in: $0) })
        for word in Set(numberWords(in: allText)).subtracting(factWords).sorted() {
            found.append(.spelledOutNumber(word))
        }

        let writtenSet = Set(written)
        for number in facts.requiredNumbers where !writtenSet.contains(number) {
            found.append(.missingRequiredNumber(number))
        }

        // ---- Verdict wording -------------------------------------------
        if !verdicts(mentionedIn: headline).contains(facts.verdict) {
            found.append(.verdictMissing)
        }
        for other in verdicts(mentionedIn: allText).subtracting([facts.verdict])
            .sorted(by: { $0.rawValue < $1.rawValue }) {
            found.append(.verdictContradicted(other))
        }

        return found
    }

    // MARK: Verdict phrases

    /// Checked in this order; each match is blanked out before the next
    /// class is searched, so "not safe to fly" can't also read as GO and
    /// "no-go" can't also read as "go".
    private static let verdictPhrases: [(Verdict, [String])] = [
        (.noGo, [
            #"\bno[\s-]*go\b"#,
            #"\bdo not (?:fly|launch)\b"#,
            #"\bdon't (?:fly|launch)\b"#,
            #"\bnot (?:safe|ok|okay|good|clear) to fly\b"#,
            #"\bunsafe\b"#,
            #"\bgrounded\b"#,
            #"\bnot flyable\b"#,
        ]),
        (.caution, [
            #"\bcaution\w*\b"#,
            #"\bmarginal\w*\b"#,
        ]),
        (.go, [
            #"\bgo\b"#,
            #"\b(?:clear|good|safe|ok|okay|fine) to fly\b"#,
            #"\bflyable\b"#,
            #"\bgreen light\b"#,
        ]),
    ]

    static func verdicts(mentionedIn text: String) -> Set<Verdict> {
        var remaining = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")   // curly apostrophe
            .replacingOccurrences(of: "\u{2010}", with: "-")   // hyphen
            .replacingOccurrences(of: "\u{2011}", with: "-")   // non-breaking hyphen
        var found = Set<Verdict>()
        for (verdict, patterns) in verdictPhrases {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(remaining.startIndex..., in: remaining)
                if regex.firstMatch(in: remaining, options: [], range: range) != nil {
                    found.insert(verdict)
                    remaining = regex.stringByReplacingMatches(
                        in: remaining, options: [], range: range, withTemplate: " ")
                }
            }
        }
        return found
    }

    // MARK: Helpers

    private static let numberWordPattern =
        #"\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|"#
        + #"thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|"#
        + #"thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|dozen)\b"#

    static func numberWords(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: numberWordPattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap {
            Range($0.range, in: text).map { text[$0].lowercased() }
        }
    }

    /// Sentence ends are ".", "!" or "?" followed by whitespace or the end
    /// of the text — so "17.9" stays one token.
    static func sentenceCount(_ text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+"#) else { return 1 }
        let range = NSRange(text.startIndex..., in: text)
        let marked = regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: "\u{1E}")
        return marked.split(separator: "\u{1E}")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }
}
