//
//  ClaudeBriefingGeneratorTests.swift
//  DroneCastTests
//
//  The Anthropic Messages API request shape and response parsing, with
//  canned JSON — no network, no key.
//

import Testing
import Foundation

struct ClaudeBriefingGeneratorTests {

    private let generator = ClaudeBriefingGenerator(apiKey: "test-key", model: "claude-haiku-5-5")

    @Test func noKeyMeansUnavailable() async {
        #expect(await ClaudeBriefingGenerator(apiKey: nil).availability()
                == .unavailable(.missingAPIKey))
        #expect(await generator.availability() == .available)
    }

    @Test func requestCarriesHeadersAndStructuredOutputSchema() throws {
        let request = try generator.makeRequest(factsJSON: #"{"verdict":"GO"}"#, apiKey: "test-key")
        #expect(request.url == ClaudeBriefingGenerator.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == ClaudeBriefingGenerator.apiVersion)

        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["system"] as? String == BriefingPrompt.instructions)
        #expect(body["temperature"] == nil)   // sampling params 400 on current models

        let config = try #require(body["output_config"] as? [String: Any])
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(Set(schema["required"] as? [String] ?? []) == ["headline", "detail", "suggestedWindow"])

        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.first?["content"] == "FACTS:\n" + #"{"verdict":"GO"}"#)
    }

    @Test func parsesTextBlockAfterThinking() throws {
        let data = Data(#"""
            {"content":[{"type":"thinking","thinking":""},
                        {"type":"text","text":"{\"headline\":\"GO · calm\",\"detail\":\"Gusts 8 mph.\",\"suggestedWindow\":\"Best window 2 PM – 5 PM\"}"}],
             "stop_reason":"end_turn"}
            """#.utf8)
        let draft = try ClaudeBriefingGenerator.parse(data)
        #expect(draft.headline == "GO · calm")
        #expect(draft.detail == "Gusts 8 mph.")
        #expect(draft.window == "Best window 2 PM – 5 PM")
        #expect(draft.provider == .claude)
    }

    @Test func refusalAndTruncationThrow() {
        let refusal = Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)
        #expect(throws: ClaudeBriefingError.refused) { try ClaudeBriefingGenerator.parse(refusal) }

        let cut = Data(#"{"content":[{"type":"text","text":"{\"headl"}],"stop_reason":"max_tokens"}"#.utf8)
        #expect(throws: ClaudeBriefingError.truncated) { try ClaudeBriefingGenerator.parse(cut) }
    }

    @Test func apiErrorMessageIsExtracted() {
        let data = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        #expect(ClaudeBriefingGenerator.errorMessage(in: data) == "invalid x-api-key")
    }
}
