import Foundation
import Security

/// Ely.by Yggdrasil-compatible authentication helper.
/// This does not replace or modify Horizon's Microsoft account implementation.
enum ElyByAccount {
    private static let baseURL = URL(string: "https://authserver.ely.by")!
    private static let keychainService = "dev.horizon.ios.elyby"

    struct Profile: Codable {
        let id: String
        let name: String
    }

    struct Account: Codable {
        let accessToken: String
        let clientToken: String
        let selectedProfile: Profile
    }

    private struct Agent: Encodable {
        let name = "Minecraft"
        let version = 1
    }

    private struct AuthenticateRequest: Encodable {
        let agent = Agent()
        let username: String
        let password: String
        let clientToken: String
        let requestUser = true
    }

    private struct RefreshRequest: Encodable {
        let accessToken: String
        let clientToken: String
        let requestUser = true
    }

    private struct APIError: Decodable {
        let error: String?
        let errorMessage: String?
    }

    enum ElyByError: LocalizedError {
        case invalidResponse
        case server(String)
        case invalidProfile
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Ely.by devolvió una respuesta no válida."
            case .server(let message): return message
            case .invalidProfile: return "Ely.by no devolvió un perfil válido."
            case .keychain(let status): return "Error de Keychain: \(status)"
            }
        }
    }

    /// Ely.by accepts username/email. For 2FA accounts, its API may require password:code.
    static func authenticate(username: String, password: String) async throws -> Account {
        let request = AuthenticateRequest(
            username: username,
            password: password,
            clientToken: UUID().uuidString
        )
        let account: Account = try await post("auth/authenticate", body: request)
        guard isValidUUID(account.selectedProfile.id),
              !account.selectedProfile.name.isEmpty else {
            throw ElyByError.invalidProfile
        }
        try save(account)
        return account
    }

    static func refresh(_ account: Account) async throws -> Account {
        let request = RefreshRequest(
            accessToken: account.accessToken,
            clientToken: account.clientToken
        )
        let renewed: Account = try await post("auth/refresh", body: request)
        guard isValidUUID(renewed.selectedProfile.id),
              !renewed.selectedProfile.name.isEmpty else {
            throw ElyByError.invalidProfile
        }
        try save(renewed)
        return renewed
    }

    static func savedAccount() throws -> Account? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "current-account",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ElyByError.keychain(status)
        }
        return try JSONDecoder().decode(Account.self, from: data)
    }

    static func signOut() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "current-account"
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ElyByError.keychain(status)
        }
    }

    private static func save(_ account: Account) throws {
        let data = try JSONEncoder().encode(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "current-account"
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ElyByError.keychain(status) }
    }

    private static func post<T: Encodable, R: Decodable>(
        _ endpoint: String,
        body: T
    ) async throws -> R {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ElyByError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIError.self, from: data)
            throw ElyByError.server(
                apiError?.errorMessage ?? apiError?.error ?? "Ely.by respondió HTTP \(http.statusCode)."
            )
        }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw ElyByError.invalidResponse
        }
    }

    private static func isValidUUID(_ value: String) -> Bool {
        let hex = value.replacingOccurrences(of: "-", with: "")
        return hex.count == 32 && hex.allSatisfy { $0.isHexDigit }
    }
}
