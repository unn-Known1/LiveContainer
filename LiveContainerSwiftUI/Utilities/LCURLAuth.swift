//
//  LCURLAuth.swift
//  LiveContainerSwiftUI
//
//  P1-12: HMAC-based authentication for control URLs
//  (livecontainer://install?url=…, certificate?cert=&password=…).
//
//  Without auth, any installed app can drive LiveContainer to do
//  arbitrary things (install a malicious IPA, replace the signing
//  cert). We bind each control URL to:
//
//    sig    = HMAC-SHA256(key, "<verb>|<path>|<nonce>")
//    key    = 32 random bytes in the app-group keychain
//    nonce  = caller-fetched from livecontainer://challenge
//
//  The challenge endpoint returns a 16-byte nonce, valid for 60s.
//  A signed URL must include `nonce=<…>&sig=<hex>`. We reject the
//  call otherwise. The challenge URL itself is unauthenticated
//  (fetching a nonce is not a privileged action).
//

import Foundation
import Security
import CryptoKit

public enum LCURLAuth {

    public static let challengeVerb = "challenge"
    public static let sigQueryItem = "sig"
    public static let nonceQueryItem = "nonce"

    /// Service identifier for the HMAC key in the keychain.
    public static let keyService = "com.livecontainer.urlauth.hmackey"
    public static let keyAccount = "primary"

    /// Time window in seconds during which a signed URL is valid.
    public static let signedURLValidity: TimeInterval = 60

    // MARK: - HMAC key

    /// Lazily generate / read the 32-byte HMAC key from the keychain.
    /// Falls back to generation-and-store if not present.
    public static func hmacKey() -> SymmetricKey {
        if let data = LCKeychainHelper.getData(service: keyService, account: keyAccount),
           data.count == 32 {
            return SymmetricKey(data: data)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Last-resort deterministic key. This still rotates
            // implicitly when the user reinstalls (keychain gone),
            // so it is not a long-term risk.
            for i in 0..<bytes.count {
                bytes[i] = UInt8.random(in: 0...UInt8.max)
            }
        }
        let data = Data(bytes)
        _ = LCKeychainHelper.setData(data, service: keyService, account: keyAccount)
        return SymmetricKey(data: data)
    }

    // MARK: - Nonce

    /// Issue a fresh nonce. The caller passes this to the URL
    /// they're about to sign. We persist issued nonces (with
    /// timestamps) in the app-group UserDefaults so we can
    /// detect replays within the validity window.
    public static func issueNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let issued = [
            "nonce": hex,
            "issuedAt": ISO8601DateFormatter().string(from: Date())
        ] as [String: String]
        var issuedNonces = (UserDefaults.lcShared().array(forKey: "LCURLAuthIssuedNonces") as? [[String: String]]) ?? []
        issuedNonces.append(issued)
        // Garbage-collect nonces older than the validity window.
        let cutoff = Date().addingTimeInterval(-signedURLValidity)
        let formatter = ISO8601DateFormatter()
        issuedNonces = issuedNonces.filter { entry in
            guard let s = entry["issuedAt"], let d = formatter.date(from: s) else { return false }
            return d > cutoff
        }
        UserDefaults.lcShared().set(issuedNonces, forKey: "LCURLAuthIssuedNonces")
        return hex
    }

    // MARK: - Signing

    /// Sign a verb + path + nonce triple. Returns lowercase hex.
    public static func sign(verb: String, path: String, nonce: String) -> String {
        let message = "\(verb)|\(path)|\(nonce)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: hmacKey()
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Verification

    public enum ValidationError: Error, LocalizedError {
        case noNonce
        case noSignature
        case unknownNonce
        case expiredNonce
        case badSignature

        public var errorDescription: String? {
            switch self {
            case .noNonce: return "Authenticated URL required: fetch a nonce from livecontainer://challenge first."
            case .noSignature: return "Authenticated URL required: missing sig query parameter."
            case .unknownNonce: return "Unknown nonce. Fetch a fresh one from livecontainer://challenge."
            case .expiredNonce: return "Nonce expired (validity 60s). Fetch a fresh one."
            case .badSignature: return "URL signature does not match."
            }
        }
    }

    /// Validate a `livecontainer://` URL against the HMAC.
    /// Returns silently on success; throws `ValidationError` on failure.
    /// Caller is responsible for actually acting on the URL.
    public static func validate(_ url: URL) throws {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ValidationError.badSignature
        }
        let verb = url.host ?? ""
        let path = url.path
        let q = comps.queryItems ?? []
        let nonce = q.first(where: { $0.name == nonceQueryItem })?.value ?? ""
        let sig = q.first(where: { $0.name == sigQueryItem })?.value ?? ""

        if verb == challengeVerb { return }
        if nonce.isEmpty { throw ValidationError.noNonce }
        if sig.isEmpty { throw ValidationError.noSignature }

        // Look up the nonce in the issued set, check freshness.
        let issued = (UserDefaults.lcShared().array(forKey: "LCURLAuthIssuedNonces") as? [[String: String]]) ?? []
        let formatter = ISO8601DateFormatter()
        guard let entry = issued.first(where: { $0["nonce"] == nonce }),
              let s = entry["issuedAt"],
              let issuedAt = formatter.date(from: s)
        else {
            throw ValidationError.unknownNonce
        }
        if Date().timeIntervalSince(issuedAt) > signedURLValidity {
            throw ValidationError.expiredNonce
        }

        let expected = sign(verb: verb, path: path, nonce: nonce)
        if expected != sig.lowercased() {
            throw ValidationError.badSignature
        }
    }
}
