//
//  LCInstallQueue.swift
//  LiveContainerSwiftUI
//
//  P0-3: serial install queue. Replaces the silent-drop path
//  in LCAppListView.installFromUrl() and the 0.5 s delay hack
//  in LCAltStoreSourcesView.install().
//

import Foundation

/// Serializes app installs so that two concurrent install requests
/// are queued rather than silently dropped. The previous implementation
/// in `LCAppListView.installFromUrl` bailed out when
/// `installprogressVisible` was already true, losing the request.
@MainActor
public final class LCInstallQueue: ObservableObject {

    public static let shared = LCInstallQueue()

    /// Use a Task queue (serial) for installs.
    private var lastTask: Task<Void, Never>?

    /// The currently-installing URL, surfaced to the UI for visibility.
    @Published public private(set) var currentInstallURL: URL?

    private init() {}

    /// Enqueue an install. The returned task completes when the install
    /// finishes (or throws).
    @discardableResult
    public func enqueue(_ url: URL, install: @escaping (URL) async -> Void) -> Task<Void, Never> {
        // Chain onto the previous task so installs run strictly in order.
        let previous = lastTask
        let task = Task { [weak self] in
            // Wait for the previous install to complete first.
            await previous?.value
            guard let self = self else { return }
            self.currentInstallURL = url
            await install(url)
            if self.currentInstallURL == url {
                self.currentInstallURL = nil
            }
        }
        lastTask = task
        return task
    }

    /// Convenience: post the `InstallAppNotification` through the queue.
    /// Replaces the old 0.5 s `DispatchQueue.main.asyncAfter` hack in
    /// `LCAltStoreSourcesView.install`.
    public func enqueueFromNotification(_ url: URL) {
        Task { [weak self] in
            await self?.enqueue(url, install: { u in
                // Re-post the notification so the existing handler in
                // LCAppListView can run the install, but with no artificial
                // delay.
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: NSNotification.InstallAppNotification,
                        object: ["url": u]
                    )
                }
            }).value
        }
    }
}
