import Foundation

struct SmartSearchService {
    enum SearchError: LocalizedError {
        case missingAPIKey
        case emptyQuery
        case invalidResponse
        case requestFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: L10n.string("Add an API key in Settings > AI first.")
            case .emptyQuery: L10n.string("Type what you’re looking for before using Smart Search.")
            case .invalidResponse: L10n.string("The AI provider returned an unexpected search response.")
            case .requestFailed(let status, let message): L10n.format("AI search failed (%lld): %@", Int64(status), message)
            }
        }
    }

    private struct RankedResults: Decodable {
        let windowIDs: [Int]
    }

    func search(
        query: String,
        windows: [WindowItem],
        groups: [TaskGroup],
        provider: AIProvider,
        apiKey: String
    ) async throws -> [UInt32] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SearchError.missingAPIKey }
        guard !cleanQuery.isEmpty else { throw SearchError.emptyQuery }

        let groupNamesByWindowID = groups.reduce(into: [UInt32: [String]]()) { result, group in
            for windowID in group.windowIDs { result[windowID, default: []].append(group.name) }
        }
        let inventory = windows.map { window in
            let groupNames = groupNamesByWindowID[window.id, default: []].joined(separator: ", ")
            let tabTitles = window.safariTabs.prefix(12).map(\.title).joined(separator: " | ")
            let domains = window.safariTabs.prefix(12).map(\.domain).joined(separator: ", ")
            return "ID \(window.id): app=\(window.appName); title=\(window.title); groups=\(groupNames); Safari domains=\(domains); Safari tab titles=\(tabTitles)"
        }.joined(separator: "\n")
        let prompt = """
        Rank the windows that best match the user's description by meaning and task context. Return only genuinely relevant window IDs, most relevant first. Use only IDs in the inventory. App names alone are weak evidence. Return an empty list when nothing plausibly matches.

        User description: \(cleanQuery)

        Window inventory:
        \(inventory)
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "windowIDs": ["type": "array", "items": ["type": "integer"]]
            ],
            "required": ["windowIDs"],
            "additionalProperties": false
        ]

        let text: String
        switch provider {
        case .openAI:
            text = try await openAISearchJSON(prompt: prompt, schema: schema, apiKey: key)
        case .anthropic:
            text = try await anthropicSearchJSON(prompt: prompt, schema: schema, apiKey: key)
        }

        guard let json = text.data(using: .utf8) else { throw SearchError.invalidResponse }
        let validIDs = Set(windows.map(\.id))
        var seen = Set<UInt32>()
        return try JSONDecoder().decode(RankedResults.self, from: json).windowIDs
            .compactMap(UInt32.init)
            .filter { validIDs.contains($0) && seen.insert($0).inserted }
    }

    private func openAISearchJSON(prompt: String, schema: [String: Any], apiKey: String) async throws -> String {
        let body: [String: Any] = [
            "model": "gpt-5.6-terra",
            "store": false,
            "reasoning": ["effort": "low"],
            "input": [["role": "user", "content": [["type": "input_text", "text": prompt]]]],
            "text": ["format": ["type": "json_schema", "name": "smart_search", "strict": true, "schema": schema]]
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SearchError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SearchError.requestFailed(http.statusCode, providerErrorMessage(from: data))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [[String: Any]],
              let message = output.first(where: { $0["type"] as? String == "message" }),
              let parts = message["content"] as? [[String: Any]],
              let text = parts.first(where: { $0["type"] as? String == "output_text" })?["text"] as? String else {
            throw SearchError.invalidResponse
        }
        return text
    }

    private func anthropicSearchJSON(prompt: String, schema: [String: Any], apiKey: String) async throws -> String {
        let body: [String: Any] = [
            "model": "claude-opus-5",
            "max_tokens": 1024,
            "messages": [["role": "user", "content": prompt]],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": schema
                ]
            ]
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SearchError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SearchError.requestFailed(http.statusCode, providerErrorMessage(from: data))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = object["content"] as? [[String: Any]],
              let text = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw SearchError.invalidResponse
        }
        return text
    }

    private func providerErrorMessage(from data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        return error?["message"] as? String ?? L10n.string("Unknown error")
    }
}
