import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    var modelDisplayName: String {
        switch self {
        case .openAI: "GPT-5.6 Terra"
        case .anthropic: "Claude Opus 5"
        }
    }

    static let defaultsKey = "ai.provider"

    static var current: AIProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let provider = AIProvider(rawValue: raw) else { return .openAI }
            return provider
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}
