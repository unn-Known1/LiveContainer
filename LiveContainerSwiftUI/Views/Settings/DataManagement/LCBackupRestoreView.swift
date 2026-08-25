//
//  LCBackupRestoreView.swift
//  LiveContainerSwiftUI
//
//  P1-9: container backup/restore UI. The user picks a .lcbk
//  file via the system document picker; we validate the sidecar
//  and copy the container folder back into place.
//

import SwiftUI
import UniformTypeIdentifiers

struct LCBackupRestoreView: View {

    @EnvironmentObject private var sharedModel: SharedModel
    @State private var showFilePicker = false
    @State private var errorInfo = ""
    @State private var errorShow = false
    @State private var successInfo = ""
    @State private var successShow = false

    var body: some View {
        Form {
            Section {
                Text("lc.backupRestore.instructions".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    showFilePicker = true
                } label: {
                    Label("lc.backupRestore.pickFile".loc, systemImage: "doc.badge.arrow.up")
                }
            }
            Section {
                ForEach(sharedModel.apps, id: \.self) { app in
                    appRow(app)
                }
            } header: {
                Text("lc.backupRestore.perAppBackup".loc)
            }
        }
        .navigationTitle("lc.backupRestore.title".loc)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "lcbk") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                do {
                    let sidecar = try LCBackupManager.shared.restoreContainer(from: url)
                    successInfo = "Restored container \(sidecar.containerName) for \(sidecar.bundleID)."
                    successShow = true
                } catch {
                    errorInfo = "Restore failed: \(error.localizedDescription)"
                    errorShow = true
                }
            case .failure(let error):
                errorInfo = "File picker failed: \(error.localizedDescription)"
                errorShow = true
            }
        }
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc, role: .cancel) { errorShow = false }
        } message: {
            Text(errorInfo)
        }
        .alert("lc.common.success".loc, isPresented: $successShow) {
            Button("lc.common.ok".loc, role: .cancel) { successShow = false }
        } message: {
            Text(successInfo)
        }
    }

    @ViewBuilder
    private func appRow(_ app: LCAppModel) -> some View {
        DisclosureGroup {
            ForEach(app.uiContainers, id: \.folderName) { container in
                Button {
                    do {
                        let url = try LCBackupManager.shared.backupContainer(container, appInfo: app.appInfo)
                        successInfo = "Backed up to \(url.lastPathComponent)"
                        successShow = true
                    } catch {
                        errorInfo = "Backup failed: \(error.localizedDescription)"
                        errorShow = true
                    }
                } label: {
                    HStack {
                        Text(container.name)
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        } label: {
            Text(app.appInfo.displayName() ?? app.appInfo.bundleIdentifier() ?? "App")
                .font(.headline)
        }
    }
}
