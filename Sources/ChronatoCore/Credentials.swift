import Foundation
import Security

/// The Kimai connection lives in the login Keychain as one generic password
/// (JSON of `KimaiConnection`). The menu-bar app writes it; `Chronato mcp`,
/// being the same signed binary, reads it without a prompt.
///
/// Deliberately the file-based login keychain, not the data-protection one:
/// that needs a keychain-access-group entitlement, which a Developer ID app
/// can only get with a provisioning profile.
///
/// On iOS the item lives in a keychain access group shared with the widget
/// extension and the App Intents, named by the Info.plist key
/// `ChronatoKeychainGroup` (`$(AppIdentifierPrefix)com.weidhaus.chronato.shared`).
public enum Credentials {
    static let service = "com.weidhaus.chronato"
    static let account = "kimai-connection"

    /// nil only when there is no connection yet. A Keychain that refuses (access denied,
    /// locked, no GUI to ask in) throws, so nobody is told to connect again for nothing.
    public static func load() throws -> KimaiConnection? {
        var item: CFTypeRef?
        let status = withSharedGroup { match in
            var query = match
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status, reading: true) }
        return try JSONDecoder().decode(KimaiConnection.self, from: data)
    }

    public static func save(_ connection: KimaiConnection) throws {
        let data = try JSONEncoder().encode(connection)
        let status = withSharedGroup { match in
            let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecItemNotFound else { return status }
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Chronato – Kimai connection"
            #if os(iOS)
            // Widgets and intents also run while the phone is locked.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            return SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func clear() {
        _ = withSharedGroup { SecItemDelete($0 as CFDictionary) }
    }

    /// Runs `body` with the item's match attributes. On iOS they name the shared
    /// access group; a build without that entitlement (an unsigned simulator
    /// build) gets errSecMissingEntitlement and falls back to the app's own group.
    /// On macOS there is no group: the login keychain as before.
    private static func withSharedGroup(_ body: ([String: Any]) -> OSStatus) -> OSStatus {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(iOS)
        if let group = Bundle.main.object(forInfoDictionaryKey: "ChronatoKeychainGroup") as? String, !group.isEmpty {
            var shared = match
            shared[kSecAttrAccessGroup as String] = group
            let status = body(shared)
            if status != errSecMissingEntitlement { return status }
        }
        #endif
        return body(match)
    }

    public struct KeychainError: Error, LocalizedError {
        public let status: OSStatus
        var reading = false
        public var errorDescription: String? {
            let detail = "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
            return reading ? "Chronato could not read its Kimai connection from the Keychain (\(detail)). Open Chronato and allow access if macOS asks." : detail
        }
    }
}

public enum Paths {
    /// ~/Library/Application Support/Chronato, created on first use.
    /// `CHRONATO_HOME` overrides it (tests, the mock-server smoke test).
    public static var support: URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["CHRONATO_HOME"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Chronato", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// AI-agent allowlist and booking defaults (`AIConfig`).
    public static var agentsFile: URL { support.appendingPathComponent("agents.json") }

    /// One JSON file per open AI-agent session (`AgentSession`).
    public static var sessionsDir: URL {
        let dir = support.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
