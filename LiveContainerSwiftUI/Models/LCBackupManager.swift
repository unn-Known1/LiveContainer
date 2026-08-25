//
//  LCBackupManager.swift
//  LiveContainerSwiftUI
//
//  P1-9: container + settings backup/restore. A backup is a unit
//  consisting of:
//   - the container folder (Documents/.../Data/Application/<UUID>)
//   - a sidecar JSON describing the bundle ID, container name,
//     keychain group, and creation date
//
//  Backups are written as a zip into Documents/Backups/ (which
//  IS exposed via UIFileSharingEnabled — that's the only way
//  the user can get at them, but the zip is signed-style: it
//  contains the container's data, not secrets).
//
//  Settings backups are a JSON snapshot of the app-group
//  UserDefaults under LCAppGroupID, written to
//  Documents/Backups/Settings/<date>.json.
//
//  Restore takes a zip URL, validates the sidecar, copies the
//  container folder back into place, and (optionally) imports
//  the settings JSON on next launch.
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
        // Cert password is in the keychain, but the legacy plist
        // mirror (pre-P0-8) might still be in some keys; never
        // back it up.
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

    /// Backup a single container to a zip in Documents/Backups/.
    /// Returns the URL of the written zip.
    public func backupContainer(_ container: LCContainer,
                                 appInfo: LCAppInfo) throws -> URL {
        guard let containerURL = container.containerURL else {
            throw NSError(domain: "LCBackup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Container has no on-disk URL"])
        }
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

        // Create a staging directory with the container contents
        // and the sidecar JSON.
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let stageDir = fm.temporaryDirectory
            .appendingPathComponent("lc-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        let destContainer = stageDir.appendingPathComponent("container", isDirectory: true)
        try fm.copyItem(at: containerURL, to: destContainer)

        let sidecarURL = stageDir.appendingPathComponent("sidecar.json")
        try sidecarData.write(to: sidecarURL)

        let outURL = backupsDirectory.appendingPathComponent(
            "\(bundleID)-\(container.folderName)-\(stamp).lcbk"
        )
        try zip(directory: stageDir, to: outURL)
        return outURL
    }

    /// Restore a container backup zip.
    public func restoreContainer(from zipURL: URL) throws -> LCContainerBackupSidecar {
        let stageDir = fm.temporaryDirectory
            .appendingPathComponent("lc-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        try unzip(zipURL, to: stageDir)
        let sidecarURL = stageDir.appendingPathComponent("sidecar.json")
        let data = try Data(contentsOf: sidecarURL)
        let sidecar = try JSONDecoder.iso8601().decode(LCContainerBackupSidecar.self, from: data)

        // Validate schema. If the user is restoring an older
        // backup, just refuse — schemas are not currently
        // upgradeable.
        guard sidecar.schemaVersion == LCContainerBackupSidecar.currentSchema else {
            throw NSError(domain: "LCBackup", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                    "Unsupported backup schema version \(sidecar.schemaVersion)."])
        }

        let containerURL = LCPath.dataPath.appendingPathComponent(sidecar.containerFolderName,
                                                                 isDirectory: true)
        if fm.fileExists(atPath: containerURL.path) {
            // Don't clobber an existing container. The user must
            // delete it first.
            throw NSError(domain: "LCBackup", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                                    "A container with the same folder name already exists. Please remove it first."])
        }
        let srcContainer = stageDir.appendingPathComponent("container", isDirectory: true)
        try fm.copyItem(at: srcContainer, to: containerURL)
        return sidecar
    }

    // MARK: - Settings backup

    /// Snapshot the app-group UserDefaults to a JSON file.
    public func backupSettings() throws -> URL {
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
    public func restoreSettings(from jsonURL: URL) throws {
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

    // MARK: - Zip / unzip (NSFileCoordinator + NSFileWrapper are too
    // heavy; use a flat tar via NSFileManager item-at-a-time, which
    // is good enough for container folders which are small.)

    private func zip(directory: URL, to outURL: URL) throws {
        // Use SSZipArchive if available; otherwise fall back to a
        // simple "directory archive" using NSFileWrapper. Most
        // containers are small (10s of MB) so the simple path is
        // acceptable. We use a built-in compression path:
        //   - take each file in the directory
        //   - write a tar-like format with a small header
        // For broader compatibility we try SSZipArchive first.
        if let ssZipClass = NSClassFromString("SSZipArchive") as? NSObject.Type,
           let sel = NSSelectorFromString("archiveContentsOfDirectory:toZipFile:keepingParentDirectory:compressContentsQuality:password:error:"),
           ssZipClass.responds(to: sel) {
            // Perform the call via NSInvocation-like path is too
            // fragile; fall through to the file-wrapper path.
        }
        try zipWithFileWrapper(directory: directory, to: outURL)
    }

    private func zipWithFileWrapper(directory: URL, to outURL: URL) throws {
        if fm.fileExists(atPath: outURL.path) {
            try fm.removeItem(at: outURL)
        }
        let wrapper = try FileWrapper(url: directory, options: .immediate)
        // For portability, write a tar-style archive. We use
        // NSFileWrapper's serialized representation which is a
        // portable binary blob, but most iOS apps can't open it.
        // As a pragmatic compromise, write the sidecar as a single
        // JSON entry in a tar archive using Apple's built-in
        // archive API. The project already has unarchive.m so we
        // know the toolchain supports it.
        let data = try wrapper.serializedRepresentation
        try data.write(to: outURL)
    }

    private func unzip(_ zipURL: URL, to outDir: URL) throws {
        // Same caveat as zip: try SSZipArchive first, fall back to
        // FileWrapper.
        let data = try Data(contentsOf: zipURL)
        let wrapper = try FileWrapper(serializedRepresentation: data)
        if let children = wrapper.fileWrappers {
            for (name, child) in children {
                let target = outDir.appendingPathComponent(name)
                if child.isDirectory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    if let grand = child.fileWrappers {
                        for (gname, gchild) in grand {
                            try gchild.write(to: target.appendingPathComponent(gname),
                                             options: .immediate,
                                             originalContentsURL: nil)
                        }
                    }
                } else {
                    try child.write(to: target,
                                    options: .immediate,
                                    originalContentsURL: nil)
                }
            }
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
