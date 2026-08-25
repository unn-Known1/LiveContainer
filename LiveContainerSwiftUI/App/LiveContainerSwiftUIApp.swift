//
//  LiveContainerSwiftUIApp.swift
//  LiveContainer
//
//  Created by s s on 2025/5/16.
//
import SwiftUI

@main
struct LiveContainerSwiftUIApp : SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // P1-15: dump any pending BSD signal crash report from the
        // previous launch. The signal handler only records metadata
        // (async-signal-safe) — the actual JSON dump + UserDefaults
        // write happens here, on the main thread.
        _ = LCSignalHandlerDumpAndClearReport()

        // P1-11: install the memory pressure monitor. The shared
        // singleton registers for didReceiveMemoryWarningNotification
        // and broadcasts .lcMemoryPressureShouldStopPiP /
        // .lcMemoryPressureShouldEvictLRU. Scenes that care (the
        // multitask dock, PiPManager) observe these notifications.
        _ = LCMemoryPressureMonitor.shared

        // P2-E: do the synchronous filesystem enumeration OFF the
        // main thread. The previous code called
        // fm.contentsOfDirectory + LCAppInfo(bundlePath:) for every
        // .app on launch; on installs with hundreds of apps this
        // blocked the launch screen for 5-10s. Move it to a
        // detached Task and assign the results back on the main
        // actor when done.
        let fm = FileManager()
        Task.detached(priority: .userInitiated) {
            var tempAppDataFolderNames: [String] = []
            var tempTweakFolderNames: [String] = []
            var tempApps: [LCAppModel] = []
            var tempHiddenApps: [LCAppModel] = []
            var tempURLSchemes: Set<String> = DataManager.shared.model.multiLCStatus != 2 ? [] : []

            do {
                // load apps
                try fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
                let appDirs = try fm.contentsOfDirectory(atPath: LCPath.bundlePath.path)
                for appDir in appDirs {
                    if !appDir.hasSuffix(".app") { continue }
                    guard let newApp = LCAppInfo(bundlePath: "\(LCPath.bundlePath.path)/\(appDir)") else { continue }
                    newApp.relativeBundlePath = appDir
                    newApp.isShared = false
                    if newApp.isHidden {
                        tempHiddenApps.append(LCAppModel(appInfo: newApp))
                    } else {
                        tempApps.append(LCAppModel(appInfo: newApp))
                        tempURLSchemes.formUnion(newApp.urlSchemes() as? [String] ?? [])
                    }
                }
                if LCPath.lcGroupDocPath != LCPath.docPath {
                    try fm.createDirectory(at: LCPath.lcGroupBundlePath, withIntermediateDirectories: true)
                    let appDirsShared = try fm.contentsOfDirectory(atPath: LCPath.lcGroupBundlePath.path)
                    for appDir in appDirsShared {
                        if !appDir.hasSuffix(".app") { continue }
                        guard let newApp = LCAppInfo(bundlePath: "\(LCPath.lcGroupBundlePath.path)/\(appDir)") else { continue }
                        newApp.relativeBundlePath = appDir
                        newApp.isShared = true
                        if newApp.isHidden {
                            tempHiddenApps.append(LCAppModel(appInfo: newApp))
                        } else {
                            tempApps.append(LCAppModel(appInfo: newApp))
                            tempURLSchemes.formUnion(newApp.urlSchemes() as? [String] ?? [])
                        }
                    }
                }
                // load document folders
                try fm.createDirectory(at: LCPath.dataPath, withIntermediateDirectories: true)
                let dataDirs = try fm.contentsOfDirectory(atPath: LCPath.dataPath.path)
                for dataDir in dataDirs {
                    let dataDirUrl = LCPath.dataPath.appendingPathComponent(dataDir)
                    if !dataDirUrl.hasDirectoryPath { continue }
                    tempAppDataFolderNames.append(dataDir)
                }
                // load tweak folders
                try fm.createDirectory(at: LCPath.tweakPath, withIntermediateDirectories: true)
                let tweakDirs = try fm.contentsOfDirectory(atPath: LCPath.tweakPath.path)
                for tweakDir in tweakDirs {
                    let tweakDirUrl = LCPath.tweakPath.appendingPathComponent(tweakDir)
                    if !tweakDirUrl.hasDirectoryPath { continue }
                    let folderName = tweakDir.hasSuffix(".disabled") ? String(tweakDir.dropLast(".disabled".count)) : tweakDir
                    tempTweakFolderNames.append(folderName)
                }
            } catch {
                NSLog("[LC] error: \(error)")
            }

            // Hand the results back to the main actor. Swift 6
            // (Xcode 26.2) flags the previous direct use of the
            // captured `tempXxx` vars as "reference to captured
            // var in concurrently-executing code". Capture them
            // into a local `let` first.
            let apps = tempApps
            let hiddenApps = tempHiddenApps
            let dataFolders = tempAppDataFolderNames
            let tweakFolders = tempTweakFolderNames
            let urlSchemes = Array(tempURLSchemes)
            await MainActor.run {
                let model = DataManager.shared.model
                model.apps = apps
                model.hiddenApps = hiddenApps
                model.appDataFolderNames = dataFolders
                model.tweakFolderNames = tweakFolders
                if !urlSchemes.isEmpty {
                    UserDefaults.lcShared().set(urlSchemes, forKey: "LCGuestURLSchemes")
                }
            }
        }
    }
    
    var body: some Scene {
        WindowGroup(id: "Main") {
            LCTabView()
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environmentObject(DataManager.shared.model)
                .environmentObject(LCAppSortManager.shared)
        }
        
        if UIApplication.shared.supportsMultipleScenes, #available(iOS 16.1, *) {
            WindowGroup(id: "appView", for: String.self) { $id in
                if let id {
                    MultitaskAppWindow(id: id)
                }
            }

        }
    }
    
}
