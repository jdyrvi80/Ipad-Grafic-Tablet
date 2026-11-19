//
//  Security.swift
//  TabletLink
//
//  Sicurezza del collegamento.
//
//  • USB: il tunnel usbmuxd funziona solo con un iPad che ha già detto
//    "Autorizza questo computer" al Mac → canale fisico e fidato, TCP semplice.
//  • Wi-Fi: TLS 1.2 con chiave pre-condivisa (TLS-PSK, AES-128-GCM), come
//    nell'esempio Apple "Building a custom peer-to-peer protocol".
//    - Associazione: chiave derivata (HKDF-SHA256) da un PIN a 6 cifre mostrato
//      dal Mac, valido 2 minuti, su una porta separata.
//    - Sessioni: chiave casuale da 256 bit generata dal Mac, consegnata all'iPad
//      durante l'associazione (via PIN o via USB) e salvata nel Portachiavi.
//  Nessun server esterno, nessun dato lascia la rete locale.
//

import Foundation
import Network
import CryptoKit
import Security

public enum TabletSecurity {

    /// Parametri TCP a bassa latenza (Nagle disattivato, keepalive rapido).
    public static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        return tcp
    }

    /// TCP in chiaro: usato SOLO per il loopback dell'iPad raggiunto via USB.
    public static func plainParameters() -> NWParameters {
        let params = NWParameters(tls: nil, tcp: tcpOptions())
        params.serviceClass = .interactiveVideo   // priorità alta, bassa latenza
        return params
    }

    /// TLS-PSK per il Wi-Fi.
    public static func tlsParameters(key: SymmetricKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityBytes = Data(TabletWire.pskIdentity.utf8)
        let identityData = identityBytes.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, keyData as __DispatchData, identityData as __DispatchData)

        // Su piattaforme Apple TLS-PSK è supportato solo in TLS 1.2.
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        // Cast a UInt16: in alcuni SDK la costante è importata come UInt32/Int.
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

        let params = NWParameters(tls: tls, tcp: tcpOptions())
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo
        return params
    }

    /// Chiave derivata dal PIN di associazione.
    public static func pairingKey(pin: String) -> SymmetricKey {
        let ikm = SymmetricKey(data: Data(pin.utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm,
                                      salt: Data("ipad-graphic-tablet/pairing/salt".utf8),
                                      info: Data("tls-psk".utf8),
                                      outputByteCount: 32)
    }

    /// Nuovo PIN a 6 cifre (generatore crittografico di sistema).
    public static func newPIN() -> String {
        var rng = SystemRandomNumberGenerator()
        let n = UInt32.random(in: 0...999_999, using: &rng)
        return String(format: "%06u", n)
    }

    /// Nuova chiave a lungo termine da 256 bit.
    public static func newLongTermKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public static func data(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

/// Accesso minimale al Portachiavi (password generiche).
public enum KeychainStore {
    public static let service = "com.jodyriva.ipadtablet"

    @discardableResult
    public static func save(_ data: Data, account: String) -> Bool {
        delete(account: account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        #if os(iOS)
        // Sul Mac (app non sandbox) si usa il portachiavi di login classico,
        // dove questo attributo non è applicabile.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    public static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Elenco degli account salvati (usato dall'iPad per i Mac associati).
    public static func accounts(prefix: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
    }
}
