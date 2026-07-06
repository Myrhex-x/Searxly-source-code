//
//  SyncView.swift
//  SearxlyiOS
//
//  Private device-to-device sync (Settings ▸ Sync). Two directions, both server-less:
//   · Receive from Mac — import the encrypted .searxlysync file (AirDrop / Files), enter the
//     code shown on the Mac, and the bookmarks + history merge in.
//   · Send to Mac — export this iPhone's library to an encrypted file + a one-time code, share
//     it (AirDrop), and enter the code on the Mac.
//  The code is the only secret; the file is useless without it. Nothing touches a network.
//

import SwiftUI
import UniformTypeIdentifiers

struct SyncView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink { ReceiveSyncView() } label: {
                    Label(L("Receive from Another Device"), systemImage: "square.and.arrow.down")
                }
                NavigationLink { SendSyncView() } label: {
                    Label(L("Send from This iPhone"), systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Sync your bookmarks and history between your devices without a server or account. One device makes an encrypted file and a code; the other opens the file and enters the code. The file is useless to anyone without the code, and nothing is ever uploaded.")
            }
        }
        .navigationTitle(L("Sync"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
    }
}

// MARK: - Receive

private struct ReceiveSyncView: View {
    @State private var importedData: Data?
    @State private var importedName: String = ""
    @State private var code = ""
    @State private var showPicker = false
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Button {
                    showPicker = true
                } label: {
                    Label(importedData == nil ? L("Choose Sync File") : importedName,
                          systemImage: "doc.badge.plus")
                }
            } header: {
                Text("Step 1")
            } footer: {
                Text("On your Mac, choose Send, then AirDrop the file to this iPhone (or save it to Files). Here, pick that file.")
            }

            if importedData != nil {
                Section {
                    TextField("XXXX-XXXX", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: code) { error = nil }
                    Button(L("Merge")) { merge() }
                        .disabled(!SyncCrypto.isComplete(code))
                } header: {
                    Text("Step 2")
                } footer: {
                    Text("Enter the code shown on your Mac.")
                }
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if let result {
                Section {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Brand.text)
                }
            }
        }
        .navigationTitle(L("Receive"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: [SyncFile.type, .data],
                      allowsMultipleSelection: false) { outcome in
            handlePicked(outcome)
        }
    }

    private func handlePicked(_ outcome: Result<[URL], Error>) {
        result = nil; error = nil
        guard case .success(let urls) = outcome, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            error = L("Couldn't read that file."); return
        }
        importedData = data
        importedName = url.lastPathComponent
    }

    private func merge() {
        guard let data = importedData else { return }
        do {
            let bundle = try SyncCrypto.open(data, code: code)
            let added = LibraryStore.shared.importSyncBundle(bundle)
            result = String(format: L("Merged %d bookmarks and %d history items from %@."),
                            added.bookmarks, added.history, bundle.deviceName)
            Haptics.tap()
        } catch let e as SyncCrypto.SyncError {
            error = e.errorDescription
        } catch let e {
            _ = e
            error = L("Couldn't read that file.")
        }
    }
}

// MARK: - Send

private struct SendSyncView: View {
    @State private var code = SyncCrypto.generateCode()
    @State private var fileURL: URL?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(L("Your code"))
                    Spacer()
                    Text(code)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .foregroundStyle(Brand.text)
                }
                Button(L("New Code")) { regenerate() }
            } footer: {
                Text("You'll enter this code on the receiving device. Generate a fresh one any time.")
            }

            Section {
                if let fileURL {
                    ShareLink(item: fileURL) {
                        Label(L("Share Encrypted File"), systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("AirDrop the file to your Mac, then enter the code above in Searxly on the Mac. Bookmarks: \(LibraryStore.shared.bookmarks.count) · History: \(LibraryStore.shared.history.count).")
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(L("Send"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(Brand.text)
        .task(id: code) { await buildFile() }
    }

    private func regenerate() {
        code = SyncCrypto.generateCode()
    }

    private func buildFile() async {
        error = nil
        let bundle = LibraryStore.shared.exportSyncBundle()
        do {
            let data = try SyncCrypto.seal(bundle, code: code)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Searxly-\(Date().timeIntervalSince1970).searxlysync")
            try data.write(to: url, options: .atomic)
            fileURL = url
        } catch {
            self.error = L("Couldn't prepare the sync file.")
        }
    }
}

// MARK: - File type

enum SyncFile {
    /// Custom UTI so AirDrop offers "Open in Searxly" once the app declares it; falls back to
    /// plain data import in the picker regardless.
    static let type = UTType(exportedAs: "app.searxly.sync", conformingTo: .data)
    static let fileExtension = "searxlysync"
}
