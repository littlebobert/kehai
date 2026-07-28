import Foundation
import Observation
import Security

@MainActor
@Observable
final class OpenAIKeyStore {
    private static let service = "com.justin.Kehai.openai"
    private static let account = "api-key"

    var apiKey: String = ""
    var saveError: String?
    private var savedAPIKey: String = ""

    init() {
        let stored = Self.load() ?? ""
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
            Self.delete()
            savedAPIKey = ""
            saveError = nil
            return
        }

        let data = Data(value.utf8)
        Self.delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
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

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
