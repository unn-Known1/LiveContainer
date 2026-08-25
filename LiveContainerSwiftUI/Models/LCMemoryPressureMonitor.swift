//
//  LCMemoryPressureMonitor.swift
//  LiveContainerSwiftUI
//
//  P1-11: forward didReceiveMemoryWarning to all live multitask
//  scenes and apply a LRU eviction policy under sustained pressure.
//

import Foundation
import UIKit

@MainActor
public final class LCMemoryPressureMonitor {

    public static let shared = LCMemoryPressureMonitor()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func onMemoryWarning() {
        NSLog("[LC] memory warning received; running LRU eviction")
        // Step 1: stop PiP for every active scene
        NotificationCenter.default.post(name: .lcMemoryPressureShouldStopPiP, object: nil)
        // Step 2: if memory is still critical, terminate the
        // least-recently-used multitask guest.
        let available = os_proc_available_memory()
        let criticalThreshold: UInt64 = 80 * 1024 * 1024 // 80 MB
        if available < criticalThreshold {
            NSLog("[LC] available memory \(available) < 80MB; LRU-evicting one multitask guest")
            NotificationCenter.default.post(name: .lcMemoryPressureShouldEvictLRU, object: nil)
        }
    }
}

public extension Notification.Name {
    static let lcMemoryPressureShouldStopPiP = Notification.Name("lcMemoryPressureShouldStopPiP")
    static let lcMemoryPressureShouldEvictLRU = Notification.Name("lcMemoryPressureShouldEvictLRU")
}
