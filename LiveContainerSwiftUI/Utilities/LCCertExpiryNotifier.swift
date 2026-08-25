//
//  LCCertExpiryNotifier.swift
//  LiveContainerSwiftUI
//
//  P0-5: schedule a local notification 48h before the cert's
//  notAfter date. Without this, free-cert users hit silent
//  launch failures when the cert expires.
//
//  The cert parsing is in LCCertExpiryParser (ObjC) because
//  Swift's `import Security` does not expose
//  SecCertificateCopyValues or kSecOIDX509V1ValidityNotAfter
//  in the iOS 26 SDK. The ObjC helper imports the C headers
//  directly and returns the NSDate to the Swift caller.
//

import Foundation
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

            guard let notAfter = LCCertExpiryParser.notAfter(forP12Data: p12Data, password: "") else { return }

            // If the cert is already expired (or expires within the
            // lead time), schedule a "now" notification so the
            // user sees the alert immediately.
            let fireDate = max(notAfter.addingTimeInterval(-leadTime), Date())

            // Only schedule if the cert is actually still going to
            // be useful — i.e. we want to warn 48h before notAfter,
            // but if notAfter is itself in the past, don't even
            // bother.
            if notAfter <= Date() { return }

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

            center.add(request) { error in
                if let error {
                    NSLog("[LC] cert-expiry notification schedule failed: \(error)")
                }
            }
        }
    }
}
