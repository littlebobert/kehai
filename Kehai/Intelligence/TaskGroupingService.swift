import AppKit
import Foundation

struct TaskGroup: Identifiable, Codable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let windowIDs: [UInt32]
}

@MainActor
final class TaskGroupingService {
    enum GroupingError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case requestFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: L10n.string("Add an API key in Settings > AI first.")
            case .invalidResponse: L10n.string("The AI provider returned an unexpected response.")
            case .requestFailed(let status, let message): L10n.format("AI request failed (%lld): %@", Int64(status), message)
            }
        }
    }

    private struct GeneratedGroups: Decodable {
        struct Group: Decodable {
            let name: String
            let windowIDs: [Int]
        }
        let groups: [Group]
    }

    func groups(
        for windows: [WindowItem],
        events: [ActivityEvent],
        provider: AIProvider,
        apiKey: String,
        progress: (String) -> Void
    ) async throws -> [TaskGroup] {
        progress(L10n.string("Preparing screenshots…"))
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GroupingError.missingAPIKey }
        guard windows.count >= 2 else { return [] }

        let inventory = windows.map {
            "ID \($0.id): app=\($0.appName); title=\($0.title); Safari domains=\($0.safariTabs.map(\.domain).joined(separator: ", ")); Safari tab titles=\($0.safariTabs.prefix(8).map(\.title).joined(separator: " | "))"
        }.joined(separator: "\n")
        let recentTrail = events.suffix(60).map { "\($0.appName): \($0.title)" }.joined(separator: " → ")
        let labelLanguageInstruction = L10n.prefersJapanese
            ? "Write every group name in natural Japanese. Preserve app names, window titles, URLs, and identifiers in their original language."
            : "Write every group name in concise English. Preserve app names, window titles, URLs, and identifiers in their original language."
        let prompt = """
        Infer a small number of task or project contexts from these windows and their screenshots. Group by shared project, repository, client, document topic, or workflow—not by application. Put related browser, terminal, Finder, editor, and communication windows together when visual content, titles, or focus sequence support it. A window may appear in more than one group. Use only IDs shown. Omit uncertain groups. Never use app names or generic labels such as Browsing, Safari, Terminal, Communication, or Development as group names. Keep each label to four words or fewer.

        \(labelLanguageInstruction)

        Windows:
        \(inventory)

        Recent focus trail:
        \(recentTrail)
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "groups": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "windowIDs": ["type": "array", "items": ["type": "integer"]]
                        ],
                        "required": ["name", "windowIDs"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["groups"],
            "additionalProperties": false
        ]

        progress(L10n.string("Uploading and analyzing…"))
        let text: String
        switch provider {
        case .openAI:
            text = try await openAIGroupsJSON(prompt: prompt, windows: windows, schema: schema, apiKey: key)
        case .anthropic:
            text = try await anthropicGroupsJSON(prompt: prompt, windows: windows, schema: schema, apiKey: key)
        }
        progress(L10n.string("Applying groups…"))
        guard let json = text.data(using: .utf8) else { throw GroupingError.invalidResponse }
        let generated = try JSONDecoder().decode(GeneratedGroups.self, from: json)
        return Self.sanitize(generated.groups.map { ($0.name, $0.windowIDs) }, validWindowIDs: Set(windows.map(\.id)))
    }

    private func openAIGroupsJSON(
        prompt: String,
        windows: [WindowItem],
        schema: [String: Any],
        apiKey: String
    ) async throws -> String {
        var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
        for window in windows.prefix(12) {
            guard window.thumbnailIsUsable,
                  let thumbnail = window.thumbnail,
                  let encoded = jpegDataURL(for: thumbnail) else { continue }
            content.append(["type": "input_text", "text": "Screenshot for window ID \(window.id):"])
            content.append(["type": "input_image", "image_url": encoded, "detail": "low"])
        }
        let body: [String: Any] = [
            "model": "gpt-5.6-terra",
            "store": false,
            "reasoning": ["effort": "low"],
            "input": [["role": "user", "content": content]],
            "text": ["format": ["type": "json_schema", "name": "task_groups", "strict": true, "schema": schema]]
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GroupingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GroupingError.requestFailed(http.statusCode, openAIErrorMessage(from: data))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [[String: Any]],
              let message = output.first(where: { $0["type"] as? String == "message" }),
              let parts = message["content"] as? [[String: Any]],
              let text = parts.first(where: { $0["type"] as? String == "output_text" })?["text"] as? String else {
            throw GroupingError.invalidResponse
        }
        return text
    }

    private func anthropicGroupsJSON(
        prompt: String,
        windows: [WindowItem],
        schema: [String: Any],
        apiKey: String
    ) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for window in windows.prefix(12) {
            guard window.thumbnailIsUsable,
                  let thumbnail = window.thumbnail,
                  let encoded = jpegBase64(for: thumbnail) else { continue }
            content.append(["type": "text", "text": "Screenshot for window ID \(window.id):"])
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": encoded
                ]
            ])
        }
        let body: [String: Any] = [
            "model": "claude-opus-5",
            "max_tokens": 4096,
            "messages": [["role": "user", "content": content]],
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
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GroupingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GroupingError.requestFailed(http.statusCode, anthropicErrorMessage(from: data))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = object["content"] as? [[String: Any]],
              let text = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw GroupingError.invalidResponse
        }
        return text
    }

    nonisolated static func sanitize(_ groups: [(String, [Int])], validWindowIDs: Set<UInt32>) -> [TaskGroup] {
        groups.compactMap { name, generatedIDs in
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = generatedIDs.compactMap(UInt32.init).filter { validWindowIDs.contains($0) }
            guard !cleanName.isEmpty, !ids.isEmpty else { return nil }
            return TaskGroup(name: String(cleanName.prefix(48)), windowIDs: Array(Set(ids)).sorted())
        }
    }

    private func openAIErrorMessage(from data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        return error?["message"] as? String ?? L10n.string("Unknown error")
    }

    private func anthropicErrorMessage(from data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        return error?["message"] as? String ?? L10n.string("Unknown error")
    }

    private func jpegDataURL(for image: NSImage) -> String? {
        guard let data = jpegData(for: image) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private func jpegBase64(for image: NSImage) -> String? {
        jpegData(for: image)?.base64EncodedString()
    }

    private func jpegData(for image: NSImage) -> Data? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        let maximum = CGSize(width: 448, height: 280)
        let scale = min(maximum.width / CGFloat(source.width), maximum.height / CGFloat(source.height), 1)
        let width = max(1, Int(CGFloat(source.width) * scale))
        let height = max(1, Int(CGFloat(source.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: resized)
        return representation.representation(using: .jpeg, properties: [.compressionFactor: 0.55])
    }
}
