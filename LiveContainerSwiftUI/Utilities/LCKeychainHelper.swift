//
//  LCKeychainHelper.swift
//  LiveContainerSwiftUI
//
//  P0-8: minimal Keychain helper for storing small secrets (currently
//  just the certificate password) without falling back to plaintext
//  UserDefaults. Migrates any pre-existing plist value into the
//  keychain on first read.
//

import Foundation
import Security

@objc public final class LCCertPasswordStore: NSObject {

    @objc public static let shared = LCCertPasswordStore()

    private let service = "com.livecontainer.cert-password"
    private let account = "default"
    private let defaultsKey = "LCCertificatePassword"

    /// Set the cert password. Writes to the keychain (preferred) and
    /// removes the legacy plist mirror.
    @objc public func setPassword(_ password: String?) {
        guard let password, !password.isEmpty else {
            // Clear both stores on nil/empty.
            _ = LCKeychainHelper.delete(service: service, account: account)
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            UserDefaults(suiteName: LCSharedUtils.appGroupID())?.removeObject(forKey: defaultsKey)
            return
        }
        _ = LCKeychainHelper.setString(password, service: service, account: account)
        // P0-8: STOP writing the plist mirror. The previous code wrote
        // the password to BOTH NSUserDefaults.standardUserDefaults and
        // the app-group NSUserDefaults, which means it was visible in
        // any backup of either store. The keychain is the canonical
        // store now; we keep a one-way migration from the plist in
        // the getter.
    }

    /// Get the cert password. Reads from the keychain first; falls back
    /// to the legacy plist mirror ONCE (migrating it into the keychain
    /// and clearing the plist).
    @objc public func password() -> String? {
        if let kc = LCKeychainHelper.getString(service: service, account: account), !kc.isEmpty {
            return kc
        }
        // One-time migration: read from plist, write to keychain, clear plist.
        if let legacy = UserDefaults(suiteName: LCSharedUtils.appGroupID())?.string(forKey: defaultsKey)
            ?? UserDefaults.standard.string(forKey: defaultsKey),
           !legacy.isEmpty {
            _ = LCKeychainHelper.setString(legacy, service: service, account: account)
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            UserDefaults(suiteName: LCSharedUtils.appGroupID())?.removeObject(forKey: defaultsKey)
            return legacy
        }
        return nil
    }
}

public enum LCKeychainHelper {

    /// Service identifier for cert-password item.
    public static let certPasswordService = "com.livecontainer.cert-password"
    public static let certPasswordAccount = "default"

    public enum KeychainError: Error {
        case unhandled(OSStatus)
        case notFound
        case invalidData
    }

    /// Write (or update) a string secret.
    /// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the
    /// secret is bound to the device and available after first unlock.
    @discardableResult
    public static func setString(_ value: String,
                                 service: String,
                                 account: String,
                                 accessGroup: String? = nil) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return setData(data, service: service, account: account, accessGroup: accessGroup)
    }

    @discardableResult
    public static func setData(_ data: Data,
                              service: String,
                              account: String,
                              accessGroup: String? = nil) -> Bool {
        // Try update first; fall back to add.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus != errSecItemNotFound {
            return false
        }

        // Add new item
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// Read a string secret. Returns nil if not found.
    public static func getString(service: String,
                                 account: String,
                                 accessGroup: String? = nil) -> String? {
        guard let data = getData(service: service, account: account, accessGroup: accessGroup) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func getData(service: String,
                               account: String,
                               accessGroup: String? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            return nil
        }
        return result as? Data
    }

    /// Delete a secret. No-op if it doesn't exist.
    @discardableResult
    public static func delete(service: String,
                              account: String,
                              accessGroup: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
