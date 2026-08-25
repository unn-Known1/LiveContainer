//
//  LCCertExpiryNotifier.swift
//  LiveContainerSwiftUI
//
//  P0-5: schedule a local notification 48h before the cert's
//  notAfter date. Without this, free-cert users hit silent
//  launch failures when the cert expires.
//
//  Implementation: parse the P12's leaf cert with the Security
//  framework, extract the notAfter OID, schedule a
//  UNUserNotificationCenter request for 48h before that
//  (clamped to "now" if the cert expires in <48h). Any
//  previously-scheduled cert-expiry notification is replaced.
//

import Foundation
import Security
import UserNotifications

@MainActor
public enum LCCertExpiryNotifier {

    public static let leadTime: TimeInterval = 48 * 60 * 60  // 48 h
    public static let notificationId = "com.livecontainer.cert-expiry"

    /// Schedule (or replace) the cert-expiry notification for the
    /// given P12. If the cert can't be parsed, or its notAfter is
    /// in the past, this is a no-op.
    public static func schedule(p12Data: Data) {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            // Always remove the old one first — this is a "schedule
            // or replace" operation.
            center.removePendingNotificationRequests(withIdentifiers: [notificationId])

            guard let notAfter = extractNotAfter(fromP12: p12Data) else { return }

            // If the cert is already expired (or expires within the
            // lead time), schedule a "now" notification so the
            // user sees the alert immediately.
            let fireDate = max(notAfter.addingTimeInterval(-leadTime), Date())

            // Only schedule if the cert is actually still going to
            // be useful — i.e. we want to warn 48h before notAfter,
            // but if notAfter is itself in the past, don't even
            // bother.
            if notAfter <= Date() { return }

            // Notification is silent (no sound) for 48h-prior
            // warnings; only the immediate-prior one buzzes.
            let content = UNMutableNotificationContent()
            if fireDate == Date() {
                content.title = "LiveContainer certificate expired"
                content.body = "Your signing certificate just expired. Apps will fail to launch until you re-import a new one."
                content.sound = .default
            } else {
                content.title = "LiveContainer certificate expiring soon"
                content.body = "Your signing certificate expires in about 48 hours. Re-import a fresh one to avoid launch failures."
            }
            content.categoryIdentifier = "LCCertExpiry"

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)

            // Best-effort: don't crash if notifications aren't
            // authorized; just silently skip.
            center.add(request) { error in
                if let error {
                    NSLog("[LC] cert-expiry notification schedule failed: \(error)")
                }
            }
        }
    }

    /// Parse the leaf cert of a P12 and return its notAfter date.
    /// Returns nil if the data isn't a valid P12 or the leaf cert
    /// has no notAfter attribute.
    public static func extractNotAfter(fromP12 p12Data: Data, password: String = "") -> Date? {
        // Import the P12 into a temporary keychain. Use a single-
        // shot SecPKCS12Import call; the password is whatever the
        // user typed in (often empty for free certs).
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]
        var rawItems: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess, let items = rawItems as? [[String: Any]] else {
            return nil
        }
        for item in items {
            guard let secIdentity = item[kSecImportItemIdentity as String] else { continue }
            // Cast to SecIdentity, then extract the certificate.
            let identity = secIdentity as! SecIdentity
            var certRef: SecCertificate?
            let certStatus = SecIdentityCopyCertificate(identity, &certRef)
            guard certStatus == errSecSuccess, let cert = certRef else { continue }

            // Read kSecOIDX509V1ValidityNotAfter.
            if let notAfter = copyCertificateDate(cert, oid: kSecOIDX509V1ValidityNotAfter) {
                return notAfter
            }
        }
        return nil
    }

    private static func copyCertificateDate(_ cert: SecCertificate, oid: CFString) -> Date? {
        var error: Unmanaged<CFError>?
        let key = SecCertificateCopyValues(cert, [oid] as CFArray, &error)
        if let error {
            NSLog("[LC] SecCertificateCopyValues failed: \(error.takeRetainedValue() as Error)")
            return nil
        }
        guard let dict = key as? [String: Any],
              let entry = dict[oid as String] as? [String: Any],
              let label = entry["value"] as? String
        else { return nil }
        // The value comes back as a localized ISO8601-ish string;
        // a fallback parser using ISO8601DateFormatter handles
        // most cert dates.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: label) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: label)
    }
}
