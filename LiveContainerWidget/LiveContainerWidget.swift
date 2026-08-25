//
//  LiveContainerWidget.swift
//  LiveContainerWidget
//
//  P1-14: WidgetKit widget showing the 3 most-recently-launched
//  apps. Reads the LCRecentAppBundleIDs key from the app-group
//  UserDefaults. Each entry is a deep link of the form
//  livecontainer://launch?bundleId=…&nonce=…&sig=… (the HMAC
//  signing comes from LCURLAuth; P1-12).
//
//  NOTE: this file is a starting point. To actually ship a
//  widget, you need to:
//    1. Add a Widget Extension target in Xcode (File → New →
//       Target → Widget Extension), name it LiveContainerWidget,
//       point it at this directory, and embed it in the host
//       app. The pbxproj is too fragile to edit by hand.
//    2. Make sure the widget extension's App Group capability
//       matches the host's app group.
//    3. In the host's LCAppModel.runApp() (or equivalent launch
//       site), push the bundle ID into LCRecentAppBundleIDs
//       before launching.
//    4. Add a deep-link handler in LCAppListView.handleURL() for
//       livecontainer://launch?bundleId=… that opens the app
//       directly. (Already partially there.)
//

import WidgetKit
import SwiftUI

@main
struct LiveContainerWidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 17.0, *) {
            RecentAppsWidget()
        }
    }
}

@available(iOS 17.0, *)
struct RecentAppsWidget: Widget {
    let kind: String = "com.livecontainer.recent-apps"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentAppsProvider()) { entry in
            RecentAppsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recent Apps")
        .description("Quickly launch the apps you've recently opened in LiveContainer.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@available(iOS 17.0, *)
struct RecentAppsProvider: TimelineProvider {
    typealias Entry = RecentAppsEntry

    func placeholder(in context: Context) -> RecentAppsEntry {
        RecentAppsEntry(date: Date(), bundleIDs: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentAppsEntry) -> Void) {
        completion(RecentAppsEntry(date: Date(), bundleIDs: Self.recentBundleIDs(limit: 3)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentAppsEntry>) -> Void) {
        let entry = RecentAppsEntry(date: Date(), bundleIDs: Self.recentBundleIDs(limit: 3))
        // Refresh in 15 min — the recents list changes on each launch.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    /// Read up to `limit` recent bundle IDs from the app-group defaults.
    /// The host writes to this key in LCAppModel.runApp().
    static func recentBundleIDs(limit: Int) -> [String] {
        let key = "LCRecentAppBundleIDs"
        guard let shared = UserDefaults(suiteName: appGroupID()),
              let arr = shared.array(forKey: key) as? [String] else {
            return []
        }
        return Array(arr.prefix(limit))
    }

    private static func appGroupID() -> String {
        return UserDefaults.standard.string(forKey: "LCAppGroupID") ?? ""
    }
}

@available(iOS 17.0, *)
struct RecentAppsEntry: TimelineEntry {
    let date: Date
    let bundleIDs: [String]
}

@available(iOS 17.0, *)
struct RecentAppsWidgetView: View {
    let entry: RecentAppsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if entry.bundleIDs.isEmpty {
                Text("No recent apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.bundleIDs.prefix(3), id: \.self) { bid in
                    Link(destination: launchURL(bundleID: bid)) {
                        HStack(spacing: 4) {
                            Image(systemName: "app.fill")
                                .imageScale(.small)
                            Text(displayName(for: bid))
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func displayName(for bundleID: String) -> String {
        // The widget runs in a separate process; we can't read
        // DataManager. Use the last path component of the bundle
        // ID as a friendly fallback. The host should write
        // display-name metadata into the recents array in a
        // follow-up if a better name is needed.
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    private func launchURL(bundleID: String) -> URL {
        // Authenticated deep link. The widget process has access
        // to the same keychain (via app-group), so it can sign the
        // URL with LCURLAuth.sign(...).
        let nonce = LCURLAuth.issueNonce()
        let sig = LCURLAuth.sign(verb: "livecontainer-launch", path: "/", nonce: nonce)
        var comps = URLComponents()
        comps.scheme = "livecontainer"
        comps.host = "livecontainer-launch"
        comps.path = "/"
        comps.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: LCURLAuth.nonceQueryItem, value: nonce),
            URLQueryItem(name: LCURLAuth.sigQueryItem, value: sig)
        ]
        return comps.url ?? URL(string: "livecontainer://")!
    }
}
