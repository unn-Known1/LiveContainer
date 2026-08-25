//
//  LCHiddenAppLock.swift
//  LiveContainerSwiftUI
//
//  P0-7: re-lock timer + scene-background re-lock for hidden apps.
//  The previous implementation set `isHiddenAppUnlocked = true`
//  for the entire app lifetime; this helper ensures the unlock
//  state is re-locked automatically.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public enum LCHiddenAppLock {

    /// UserDefaults key for the re-lock timeout (in seconds).
    /// 0 means "never re-lock automatically" (old behavior).
    /// Default: 300 (5 minutes).
    public static let timeoutKey = "LCHiddenAppReLockTimeoutSeconds"

    /// Current pending re-lock task, cancelled if a new unlock happens.
    private static var pendingReLockTask: Task<Void, Never>?

    /// Observer tokens for scene-background notifications.
    nonisolated(unsafe) private static var observersInstalled = false

    /// Default timeout if the user hasn't customized it.
    public static let defaultTimeout: TimeInterval = 300

    public static var currentTimeout: TimeInterval {
        let stored = LCUtils.appGroupUserDefault.double(forKey: timeoutKey)
        // Treat negative / unset (==0 from the initial double read of an
        // unset key) as the default. A user-set 0 means "never re-lock".
        if stored < 0 { return defaultTimeout }
        return stored
    }

    /// Schedule a re-lock after the configured timeout.
    /// Safe to call multiple times — the previous schedule is cancelled.
    public static func scheduleReLock() {
        installObserversIfNeeded()

        pendingReLockTask?.cancel()
        let timeout = currentTimeout
        guard timeout > 0 else {
            // 0 explicitly means "never re-lock automatically".
            return
        }
        pendingReLockTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            DataManager.shared.model.isHiddenAppUnlocked = false
        }
    }

    /// Cancel any pending re-lock. Use on explicit user actions
    /// (e.g. toggling the "hide apps" setting off).
    public static func cancelPendingReLock() {
        pendingReLockTask?.cancel()
        pendingReLockTask = nil
    }

    /// Re-lock immediately (used by scene-background observer).
    public static func reLockNow() {
        pendingReLockTask?.cancel()
        pendingReLockTask = nil
        DataManager.shared.model.isHiddenAppUnlocked = false
    }

    /// Install scene-phase / app-background observers the first time
    /// we're used. Observers are de-duplicated so we never double-install.
    private static func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                reLockNow()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                reLockNow()
            }
        }
        #endif
    }
}
