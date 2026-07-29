import Foundation
import Observation
import Security

@MainActor
@Observable
final class APIKeyStore {
    private let service: String
    private let account = "api-key"

    var apiKey: String = ""
    var saveError: String?
    private var savedAPIKey: String = ""

    init(service: String) {
        self.service = service
        let stored = Self.load(service: service) ?? ""
        apiKey = stored
        savedAPIKey = stored
    }

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasSavedKey: Bool { !savedAPIKey.isEmpty }
    var hasUnsavedChanges: Bool { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) != savedAPIKey }
    var canSave: Bool { hasKey && hasUnsavedChanges }

    func save() {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            Self.delete(service: service)
            savedAPIKey = ""
            saveError = nil
            return
        }

        let data = Data(value.utf8)
        Self.delete(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            apiKey = value
            savedAPIKey = value
            saveError = nil
        } else {
            saveError = L10n.format("Could not save the API key (error %lld).", Int64(status))
        }
    }

    static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

typealias OpenAIKeyStore = APIKeyStore
typealias AnthropicKeyStore = APIKeyStore

extension APIKeyStore {
    static func openAI() -> APIKeyStore { APIKeyStore(service: "com.justin.Kehai.openai") }
    static func anthropic() -> APIKeyStore { APIKeyStore(service: "com.justin.Kehai.anthropic") }
}
