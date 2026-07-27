import Foundation

struct SmartSearchService {
    enum SearchError: LocalizedError {
        case missingAPIKey
        case emptyQuery
        case invalidResponse
        case requestFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "Add an OpenAI API key in Setup & Permissions first."
            case .emptyQuery: "Type what you’re looking for before using Smart Search."
            case .invalidResponse: "OpenAI returned an unexpected search response."
            case .requestFailed(let status, let message): "OpenAI search failed (\(status)): \(message)"
            }
        }
    }

    private struct RankedResults: Decodable {
        let windowIDs: [Int]
    }

    func search(query: String, windows: [WindowItem], groups: [TaskGroup], apiKey: String) async throws -> [UInt32] {
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
        let body: [String: Any] = [
            "model": "gpt-5.6-terra",
            "store": false,
            "reasoning": ["effort": "low"],
            "input": [["role": "user", "content": [["type": "input_text", "text": prompt]]]],
            "text": ["format": ["type": "json_schema", "name": "smart_search", "strict": true, "schema": schema]]
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SearchError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            throw SearchError.requestFailed(http.statusCode, error?["message"] as? String ?? "Unknown error")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [[String: Any]],
              let message = output.first(where: { $0["type"] as? String == "message" }),
              let parts = message["content"] as? [[String: Any]],
              let text = parts.first(where: { $0["type"] as? String == "output_text" })?["text"] as? String,
              let json = text.data(using: .utf8) else { throw SearchError.invalidResponse }

        let validIDs = Set(windows.map(\.id))
        var seen = Set<UInt32>()
        return try JSONDecoder().decode(RankedResults.self, from: json).windowIDs
            .compactMap(UInt32.init)
            .filter { validIDs.contains($0) && seen.insert($0).inserted }
    }
}
