//
//  BriefingCardView.swift
//  DroneCast — Views
//
//  The plain-English briefing under the score. Identical layout whether
//  the text came from the model or the template — only the small source
//  tag in the corner differs.
//

import SwiftUI

struct BriefingCardView: View {
    let briefing: Briefing

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(briefing.headline)
                    .font(.caption.bold())
                    .foregroundStyle(briefing.verdict.tint)
                    .lineLimit(2)
                Spacer(minLength: 2)
                SourceTag(source: briefing.source)
            }

            Text(briefing.detail)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)

            Label(briefing.window, systemImage: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Briefing, \(briefing.source.spokenLabel)")
        .accessibilityValue(spokenValue)
    }

    /// VoiceOver reads "NO-GO" as "no dash go".
    private var spokenValue: String {
        briefing.spokenText
            .replacingOccurrences(of: Verdict.noGo.rawValue, with: Verdict.noGo.spokenLabel)
    }
}

private struct SourceTag: View {
    let source: Briefing.Source

    var body: some View {
        Label(source.shortLabel, systemImage: source.symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.gray.opacity(0.25), in: Capsule())
    }
}

extension Briefing.Source {
    var shortLabel: String {
        switch self {
        case .ai:       return "AI"
        case .template: return "Template"
        }
    }

    var symbol: String {
        switch self {
        case .ai:       return "sparkles"
        case .template: return "text.alignleft"
        }
    }

    var spokenLabel: String {
        switch self {
        case .ai:       return "written by Apple Intelligence"
        case .template: return "from template"
        }
    }
}
