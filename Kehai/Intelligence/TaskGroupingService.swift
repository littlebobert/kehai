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
            case .missingAPIKey: "Add an OpenAI API key in Setup & Permissions first."
            case .invalidResponse: "OpenAI returned an unexpected response."
            case .requestFailed(let status, let message): "OpenAI request failed (\(status)): \(message)"
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
        apiKey: String,
        progress: (String) -> Void
    ) async throws -> [TaskGroup] {
        progress("Preparing screenshots…")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GroupingError.missingAPIKey }
        guard windows.count >= 2 else { return [] }

        let inventory = windows.map {
            "ID \($0.id): app=\($0.appName); title=\($0.title); Safari domains=\($0.safariTabs.map(\.domain).joined(separator: ", ")); Safari tab titles=\($0.safariTabs.prefix(8).map(\.title).joined(separator: " | "))"
        }.joined(separator: "\n")
        let recentTrail = events.suffix(60).map { "\($0.appName): \($0.title)" }.joined(separator: " → ")
        let prompt = """
        Infer a small number of task or project contexts from these windows and their screenshots. Group by shared project, repository, client, document topic, or workflow—not by application. Put related browser, terminal, Finder, editor, and communication windows together when visual content, titles, or focus sequence support it. A window may appear in more than one group. Use only IDs shown. Omit uncertain groups. Never use app names or generic labels such as Browsing, Safari, Terminal, Communication, or Development as group names. Keep each label to four words or fewer.

        Windows:
        \(inventory)

        Recent focus trail:
        \(recentTrail)
        """

        var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
        for window in windows.prefix(12) {
            guard window.thumbnailIsUsable,
                  let thumbnail = window.thumbnail,
                  let encoded = jpegDataURL(for: thumbnail) else { continue }
            content.append(["type": "input_text", "text": "Screenshot for window ID \(window.id):"])
            content.append(["type": "input_image", "image_url": encoded, "detail": "low"])
        }

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
        let body: [String: Any] = [
            "model": "gpt-5.6-terra",
            "store": false,
            "reasoning": ["effort": "low"],
            "input": [["role": "user", "content": content]],
            "text": ["format": ["type": "json_schema", "name": "task_groups", "strict": true, "schema": schema]]
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        progress("Uploading and analyzing…")
        let (data, response) = try await URLSession.shared.data(for: request)
        progress("Applying groups…")
        guard let http = response as? HTTPURLResponse else { throw GroupingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            throw GroupingError.requestFailed(http.statusCode, error?["message"] as? String ?? "Unknown error")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [[String: Any]],
              let message = output.first(where: { $0["type"] as? String == "message" }),
              let parts = message["content"] as? [[String: Any]],
              let text = parts.first(where: { $0["type"] as? String == "output_text" })?["text"] as? String,
              let json = text.data(using: .utf8) else {
            throw GroupingError.invalidResponse
        }
        let generated = try JSONDecoder().decode(GeneratedGroups.self, from: json)
        return Self.sanitize(generated.groups.map { ($0.name, $0.windowIDs) }, validWindowIDs: Set(windows.map(\.id)))
    }

    nonisolated static func sanitize(_ groups: [(String, [Int])], validWindowIDs: Set<UInt32>) -> [TaskGroup] {
        groups.compactMap { name, generatedIDs in
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = generatedIDs.compactMap(UInt32.init).filter { validWindowIDs.contains($0) }
            guard !cleanName.isEmpty, !ids.isEmpty else { return nil }
            return TaskGroup(name: String(cleanName.prefix(48)), windowIDs: Array(Set(ids)).sorted())
        }
    }

    private func jpegDataURL(for image: NSImage) -> String? {
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
        guard let data = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.55]) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}
