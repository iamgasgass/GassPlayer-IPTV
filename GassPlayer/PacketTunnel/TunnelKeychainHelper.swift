import Foundation

/// Copia dedicata al target PacketTunnel (estensione Network Extension):
/// i target Swift non condividono automaticamente i file sorgente tra loro,
/// quindi KeychainHelper definito per il target principale GassPlayer non e'
/// visibile qui. Le voci Keychain create dal processo principale con
/// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly sono leggibili anche da
/// questa estensione perche' entrambi i target condividono lo stesso Team ID
/// di firma — non serve un Keychain Access Group esplicito per
/// kSecClassGenericPassword nello stesso team, ma se in Xcode e' gia'
/// configurato un App Group condiviso tra i due target, usarlo e' comunque
/// la pratica piu' robusta (aggiungere kSecAttrAccessGroup qui e nella
/// funzione gemella in ProviderVPNManager.swift con lo stesso identifier).
enum TunnelKeychainHelper {
    static func readSecret(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
