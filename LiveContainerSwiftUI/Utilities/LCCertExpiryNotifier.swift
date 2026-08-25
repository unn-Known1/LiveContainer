//
//  LCCertExpiryNotifier.swift
//  LiveContainerSwiftUI
//
//  P0-5: warn the user 48h before their cert expires.
//
//  Why a pure-Swift ASN.1 parser instead of
//  SecCertificateCopyValues: the latter requires the
//  kSecOIDX509V1ValidityNotAfter constant, which is in a
//  private SPI header in the iOS 26 SDK and isn't bridged
//  to Swift. So we walk the X.509 DER ourselves, skip past
//  Version / serialNumber / signature / issuer to the
//  Validity SEQUENCE, and read the notAfter Time.
//
//  X.509 structure (RFC 5280):
//    Certificate ::= SEQUENCE { tbsCertificate, sigAlg, sig }
//    TBSCertificate ::= SEQUENCE {
//        version [0] EXPLICIT DEFAULT v1,
//        serialNumber INTEGER,
//        signature AlgorithmIdentifier,
//        issuer Name,
//        validity Validity,        <-- we want this
//        ...
//    }
//    Validity ::= SEQUENCE { notBefore Time, notAfter Time }
//    Time ::= CHOICE { utcTime UTCTime, generalTime GeneralizedTime }
//
//  We only need the leaf cert's notAfter, so we use
//  SecPKCS12Import → SecIdentityRef → SecCertificateRef
//  → SecCertificateCopyData and walk the DER.
//

import Foundation
import Security
import UserNotifications

@MainActor
public final class LCCertExpiryNotifier {
    public static let shared = LCCertExpiryNotifier()

    public static let warnWithin: TimeInterval = 48 * 3600 // 48 hours

    private let suiteName = LCSharedUtils.appGroupID() ?? ""
    private let pwdKey = "LCCertificatePassword"
    private let dataKey = "LCCertificateData"
    private let lastWarnKey = "LCCertExpiryLastWarned"
    private let lastNotAfterKey = "LCCertExpiryLastNotAfter"

    public func startPeriodicCheck() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.check()
        }
    }

    public func check() async {
        guard !suiteName.isEmpty,
              let defaults = UserDefaults(suiteName: suiteName),
              let pwd = defaults.string(forKey: pwdKey),
              let p12Data = defaults.data(forKey: dataKey),
              let notAfter = LCCertExpiryParser.notAfter(forP12: p12Data, password: pwd) else {
            return
        }
        let now = Date()
        let interval = notAfter.timeIntervalSince(now)
        let lastWarned: TimeInterval = defaults.double(forKey: lastWarnKey)
        // Re-warn at most once per 12h
        guard now.timeIntervalSince1970 - lastWarned > 12 * 3600 else { return }
        if interval <= Self.warnWithin {
            defaults.set(now.timeIntervalSince1970, forKey: lastWarnKey)
            defaults.set(notAfter.timeIntervalSince1970, forKey: lastNotAfterKey)
            LCCertExpiryNotifier.presentNotification(notAfter: notAfter)
        }
    }

    private static func presentNotification(notAfter: Date) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "lc.certExpiry.warning.title".loc
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            content.body = "lc.certExpiry.warning.body %@".localizeWithFormat(f.string(from: notAfter))
            content.sound = .default
            let req = UNNotificationRequest(identifier: "lc.cert.expiry",
                                            content: content,
                                            trigger: nil)
            center.add(req, withCompletionHandler: nil)
        }
    }
}

// MARK: - LCCertExpiryParser
//
// Pure-Swift ASN.1 parser for the notAfter field. Returns nil
// for anything we don't understand — better to silently skip
// than to crash the certificate flow.

enum LCCertExpiryParser {

    /// Returns the notAfter NSDate of the leaf certificate
    /// inside a P12 blob, or nil if the data is not a valid
    /// P12 or we can't find the notAfter field.
    static func notAfter(forP12 p12Data: Data, password: String) -> Date? {
        guard let cert = leafCert(fromP12: p12Data, password: password),
              let der = SecCertificateCopyData(cert) as Data? else {
            return nil
        }
        return parseNotAfter(from: der)
    }

    private static func leafCert(fromP12 p12Data: Data, password: String) -> SecCertificate? {
        let importOptions: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]
        var rawItems: CFArray?
        let status = SecPKCS12Import(p12Data as CFData,
                                     importOptions as CFDictionary,
                                     &rawItems)
        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]] else {
            return nil
        }
        for item in items {
            if let idRef = item[kSecImportItemIdentity as String] {
                let identity = idRef as! SecIdentity
                var cert: SecCertificate?
                _ = SecIdentityCopyCertificate(identity, &cert)
                if let cert { return cert }
            }
        }
        return nil
    }

    /// Walk a DER-encoded X.509 certificate and extract the
    /// notAfter Time field.
    private static func parseNotAfter(from der: Data) -> Date? {
        var i = 0
        // Certificate SEQUENCE
        guard readTLV(der, &i, expectedTag: 0x30) != nil else { return nil }
        // tbsCertificate SEQUENCE
        guard let tbs = readTLV(der, &i, expectedTag: 0x30) else { return nil }
        // TBS body
        var t = tbs.startIndex
        // optional [0] EXPLICIT Version (0xA0)
        if t < tbs.endIndex, der[t] == 0xA0 {
            if readTLV(der, &t, expectedTag: 0xA0) == nil { return nil }
        }
        // serialNumber INTEGER (0x02)
        if readTLV(der, &t, expectedTag: 0x02) == nil { return nil }
        // signature AlgorithmIdentifier SEQUENCE (0x30)
        if readTLV(der, &t, expectedTag: 0x30) == nil { return nil }
        // issuer Name SEQUENCE (0x30)
        if readTLV(der, &t, expectedTag: 0x30) == nil { return nil }
        // validity SEQUENCE (0x30)
        guard let validity = readTLV(der, &t, expectedTag: 0x30) else { return nil }
        // validity body
        var v = validity.startIndex
        // notBefore Time — skip
        guard readTLV(der, &v) != nil else { return nil }
        // notAfter Time — this is what we want
        guard let notAfterTLV = readTLV(der, &v) else { return nil }
        // Time is CHOICE of UTCTime (0x17) or GeneralizedTime (0x18)
        let tag = notAfterTLV.tag
        guard tag == 0x17 || tag == 0x18 else { return nil }
        // Parse the time value
        return parseTime(tag: tag, bytes: notAfterTLV.value)
    }

    /// DER TLV. Returns the (tag, value) starting at `cursor`
    /// if it matches `expectedTag` and is well-formed.
    private static func readTLV(_ der: Data, _ cursor: inout Int, expectedTag: UInt8? = nil) -> (tag: UInt8, value: Data, startIndex: Int)? {
        guard cursor < der.count else { return nil }
        let start = cursor
        let tag = der[cursor]
        if let want = expectedTag, tag != want { return nil }
        cursor += 1
        guard cursor < der.count else { return nil }
        var lengthByte = der[cursor]
        cursor += 1
        var length = 0
        if lengthByte & 0x80 == 0 {
            length = Int(lengthByte)
        } else {
            let n = Int(lengthByte & 0x7F)
            guard n > 0, n <= 4 else { return nil }
            var l = 0
            for _ in 0..<n {
                guard cursor < der.count else { return nil }
                l = (l << 8) | Int(der[cursor])
                cursor += 1
            }
            length = l
        }
        guard cursor + length <= der.count else { return nil }
        let value = der.subdata(in: cursor..<(cursor + length))
        cursor += length
        return (tag, value, start)
    }

    /// Parse UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime
    /// (YYYYMMDDHHMMSSZ) into a Date.
    private static func parseTime(tag: UInt8, bytes: Data) -> Date? {
        guard let str = String(data: bytes, encoding: .ascii) else { return nil }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        if tag == 0x17 {
            f.dateFormat = "yyMMddHHmmssZ"
        } else {
            f.dateFormat = "yyyyMMddHHmmssZ"
        }
        return f.date(from: str)
    }
}
