//
//  ClaudeBriefingGenerator.swift
//  DroneCast — Services layer (app + test targets)
//
//  Claude over the Anthropic Messages API, called straight from the watch
//  over Wi-Fi or cellular. Needs no Apple entitlement and no iPhone, so it
//  works on a free personal team — the cost is pay-as-you-go API usage
//  on your own Anthropic account (a briefing is well under a cent).
//
//  The API key comes from Config/Secrets.xcconfig (git-ignored) via the
//  DCClaudeAPIKey Info.plist entry. With no key the generator reports
//  .missingAPIKey and the chain moves on to the iPhone.
//
//  Raw URLSession: there's no official Anthropic SDK for Swift, and this
//  is one small request.
//

import Foundation

enum ClaudeConfig {
    /// Fast and cheap; plenty for rewording a dozen facts. Any current
    /// model ID works here (e.g. "claude-sonnet-5-5" or "claude-opus-5-5"
    /// for more polish at higher cost and latency).
    static let model = "claude-haiku-5-5"

    /// Read from Info.plist, which gets it from Config/Secrets.xcconfig.
    /// Nil when unset or when the build variable wasn't substituted.
    static var apiKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "DCClaudeAPIKey") as? String
        else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.hasPrefix("$("), !key.contains("REPLACE_ME") else { return nil }
        return key
    }
}

enum ClaudeBriefingError: Error, Equatable, LocalizedError {
    case http(status: Int, message: String)
    case refused
    case truncated
    case noText
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): return "Claude API \(status): \(message)"
        case .refused:     return "Claude declined the request"
        case .truncated:   return "Claude's answer was cut off"
        case .noText:      return "Claude returned no text"
        case .badResponse: return "Unreadable Claude API response"
        }
    }
}

struct ClaudeBriefingGenerator: BriefingGenerating {

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"

    let apiKey: String?
    let model: String
    let session: URLSession
    /// Per-request network timeout. Shorter than the briefing service's
    /// overall deadline so a dead connection leaves time for the iPhone.
    let requestTimeout: TimeInterval

    init(apiKey: String? = ClaudeConfig.apiKey,
         model: String = ClaudeConfig.model,
         session: URLSession = .shared,
         requestTimeout: TimeInterval = 9) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.requestTimeout = requestTimeout
    }

    func availability() async -> BriefingModelAvailability {
        apiKey == nil ? .unavailable(.missingAPIKey) : .available
    }

    func generate(from facts: BriefingFacts) async throws -> BriefingDraft {
        guard let apiKey else { throw ClaudeBriefingError.http(status: 401, message: "No API key") }
        let request = try makeRequest(factsJSON: try facts.jsonString(), apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeBriefingError.badResponse }
        guard http.statusCode == 200 else {
            throw ClaudeBriefingError.http(status: http.statusCode, message: Self.errorMessage(in: data))
        }
        return try Self.parse(data)
    }

    // MARK: Request

    func makeRequest(factsJSON: String, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(factsJSON: factsJSON))
        return request
    }

    func body(factsJSON: String) -> [String: Any] {
        [
            "model": model,
            // Room for a little adaptive thinking plus ~100 tokens of JSON.
            "max_tokens": 1024,
            "system": BriefingPrompt.instructions,
            "output_config": [
                // Rewording a dozen facts needs little reasoning; low keeps
                // latency down on a cellular watch.
                "effort": "low",
                // Structured output: the reply is guaranteed to be JSON
                // matching this schema — the counterpart of @Generable.
                "format": [
                    "type": "json_schema",
                    "schema": Self.schema,
                ],
            ],
            "messages": [
                ["role": "user", "content": BriefingPrompt.prompt(factsJSON: factsJSON)],
            ],
        ]
    }

    // Computed: a stored [String: Any] static isn't concurrency-safe in Swift 6.
    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "headline": ["type": "string", "description": BriefingPrompt.headlineGuide],
            "detail": ["type": "string", "description": BriefingPrompt.detailGuide],
            "suggestedWindow": ["type": "string", "description": BriefingPrompt.windowGuide],
        ],
        "required": ["headline", "detail", "suggestedWindow"],
        "additionalProperties": false,
    ] }

    // MARK: Response

    private struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }

    private struct Output: Decodable {
        let headline: String
        let detail: String
        let suggestedWindow: String
    }

    static func parse(_ data: Data) throws -> BriefingDraft {
        guard let message = try? JSONDecoder().decode(MessageResponse.self, from: data) else {
            throw ClaudeBriefingError.badResponse
        }
        switch message.stop_reason {
        case "refusal":    throw ClaudeBriefingError.refused
        case "max_tokens": throw ClaudeBriefingError.truncated
        default:           break
        }
        // A response can open with thinking blocks — read by type, not position.
        guard let text = message.content.first(where: { $0.type == "text" })?.text else {
            throw ClaudeBriefingError.noText
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: Data(text.utf8)) else {
            throw ClaudeBriefingError.badResponse
        }
        return BriefingDraft(headline: output.headline,
                             detail: output.detail,
                             window: output.suggestedWindow,
                             provider: .claude)
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    static func errorMessage(in data: Data) -> String {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message ?? "request failed"
    }
}
