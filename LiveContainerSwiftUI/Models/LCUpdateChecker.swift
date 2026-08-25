//
//  LCUpdateChecker.swift
//  LiveContainerSwiftUI
//
//  P1-10: in-app update checker. Compares the installed app's
//  CFBundleShortVersionString to the source's latest version and
//  reports whether a newer version is available. Also exposes a
//  comparator so callers can pick "latest of all known versions".
//

import Foundation

public enum LCUpdateChecker {

    /// Returns true if `installedVersion` is older than `sourceVersion`.
    /// Both strings are dot-separated. A leading "v" is stripped.
    public static func isOutdated(installed: String?, source: String?) -> Bool {
        guard let installed = normalize(installed),
              let source = normalize(source) else {
            return false
        }
        return compare(installed, source) < 0
    }

    /// Compare two dot-separated version strings.
    /// Returns -1 if a < b, 0 if equal, 1 if a > b.
    public static func compare(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
        let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let ai = i < aParts.count ? aParts[i] : 0
            let bi = i < bParts.count ? bParts[i] : 0
            if ai < bi { return -1 }
            if ai > bi { return 1 }
        }
        return 0
    }

    /// Pick the highest version from a list. Returns nil if empty.
    public static func latest(_ versions: [String]) -> String? {
        guard let first = versions.first else { return nil }
        return versions.reduce(first) { acc, v in
            compare(v, acc) > 0 ? v : acc
        }
    }

    private static func normalize(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        var out = s
        if out.lowercased().hasPrefix("v") {
            out = String(out.dropFirst())
        }
        return out
    }
}
