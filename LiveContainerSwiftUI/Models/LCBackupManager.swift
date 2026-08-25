//
//  LCBackupManager.swift
//  LiveContainerSwiftUI
//
//  P1-9: container + settings backup/restore. A backup is a
//  "folder archive" — a directory named `<bundleID>-<uuid>.lcbk`
//  containing:
//    - sidecar.json (bundleID, container name, keychain group,
//      isShared, createdAt, schemaVersion)
//    - container/ (the actual container folder contents)
//
//  iOS treats the .lcbk directory as a single file via the
//  document picker, and users can AirDrop / Files-app it like
//  any other artifact. On restore, validate the sidecar and
//  copy the contents back into the data path.
//
//  We deliberately avoid NSFileWrapper / SSZipArchive / libarchive
//  because each adds a dependency or compile-time complexity
//  that isn't justified for "10s of MB of container data".
//
//  Settings backup: JSON snapshot of the app-group UserDefaults
//  (with cert data and password explicitly excluded).
//

import Foundation

public struct LCContainerBackupSidecar: Codable {
    public let bundleID: String
    public let containerName: String
    public let containerFolderName: String
    public let keychainGroupId: Int
    public let isShared: Bool
    public let createdAt: Date
    public let schemaVersion: Int

    static let currentSchema = 1
}

public struct LCSettingsBackup: Codable {
    public let createdAt: Date
    public let sourceAppGroup: String
    public let keys: [String: String]

    static let excludedKeys: Set<String> = [
        "LCCertificatePassword",
        "LCCertificateData",
        "LCCertificateUpdateDate"
    ]
}

@MainActor
public final class LCBackupManager {

    public static let shared = LCBackupManager()

    private let fm = FileManager.default

    public var backupsDirectory: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("Backups", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public var settingsBackupDirectory: URL {
        let url = backupsDirectory.appendingPathComponent("Settings", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Container backup

    /// Backup a single container to a folder-archive in
    /// Documents/Backups/. Returns the URL of the written
    /// archive directory. Internal (not public) because
    /// LCContainer / LCAppInfo are internal types.
    func backupContainer(_ container: LCContainer,
                         appInfo: LCAppInfo) throws -> URL {
        let containerURL = container.containerURL
        let bundleID = appInfo.bundleIdentifier() ?? "unknown"
        let sidecar = LCContainerBackupSidecar(
            bundleID: bundleID,
            containerName: container.name,
            containerFolderName: container.folderName,
            keychainGroupId: container.keychainGroupId,
            isShared: container.isShared,
            createdAt: Date(),
            schemaVersion: LCContainerBackupSidecar.currentSchema
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sidecarData = try encoder.encode(sidecar)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let outURL = backupsDirectory.appendingPathComponent(
            "\(bundleID)-\(container.folderName)-\(stamp).lcbk",
            isDirectory: true
        )
        if fm.fileExists(atPath: outURL.path) {
            try fm.removeItem(at: outURL)
        }
        try fm.createDirectory(at: outURL, withIntermediateDirectories: true)

        let destContainer = outURL.appendingPathComponent("container", isDirectory: true)
        try fm.copyItem(at: containerURL, to: destContainer)

        let sidecarURL = outURL.appendingPathComponent("sidecar.json")
        try sidecarData.write(to: sidecarURL)
        return outURL
    }

    /// Restore a container backup folder-archive. Internal
    /// (the returned sidecar struct is public, but the method
    /// is not — callers in the same module can use it).
    func restoreContainer(from archiveURL: URL) throws -> LCContainerBackupSidecar {
        let sidecarURL = archiveURL.appendingPathComponent("sidecar.json")
        let data = try Data(contentsOf: sidecarURL)
        let sidecar = try JSONDecoder.iso8601().decode(LCContainerBackupSidecar.self, from: data)

        guard sidecar.schemaVersion == LCContainerBackupSidecar.currentSchema else {
            throw NSError(domain: "LCBackup", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                    "Unsupported backup schema version \(sidecar.schemaVersion)."])
        }

        let containerURL = LCPath.dataPath.appendingPathComponent(sidecar.containerFolderName,
                                                                 isDirectory: true)
        if fm.fileExists(atPath: containerURL.path) {
            throw NSError(domain: "LCBackup", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                                    "A container with the same folder name already exists. Please remove it first."])
        }
        let srcContainer = archiveURL.appendingPathComponent("container", isDirectory: true)
        try fm.copyItem(at: srcContainer, to: containerURL)
        return sidecar
    }

    // MARK: - Settings backup

    /// Snapshot the app-group UserDefaults to a JSON file.
    func backupSettings() throws -> URL {
        guard let groupID = LCSharedUtils.appGroupID() else {
            throw NSError(domain: "LCBackup", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "No app group configured."])
        }
        guard let shared = UserDefaults(suiteName: groupID) else {
            throw NSError(domain: "LCBackup", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot access app-group defaults."])
        }
        var keys: [String: String] = [:]
        for (k, v) in shared.dictionaryRepresentation() {
            if LCSettingsBackup.excludedKeys.contains(k) { continue }
            if let s = v as? String { keys[k] = s }
        }
        let snap = LCSettingsBackup(createdAt: Date(),
                                    sourceAppGroup: groupID,
                                    keys: keys)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snap)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = settingsBackupDirectory.appendingPathComponent("settings-\(stamp).json")
        try data.write(to: url)
        return url
    }

    /// Apply a settings JSON snapshot. Caller is responsible for
    /// restarting LiveContainer for some keys to take effect.
    func restoreSettings(from jsonURL: URL) throws {
        let data = try Data(contentsOf: jsonURL)
        let snap = try JSONDecoder.iso8601().decode(LCSettingsBackup.self, from: data)
        guard let shared = UserDefaults(suiteName: snap.sourceAppGroup) else {
            throw NSError(domain: "LCBackup", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot access app-group defaults."])
        }
        for (k, v) in snap.keys {
            shared.set(v, forKey: k)
        }
    }
}

extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
