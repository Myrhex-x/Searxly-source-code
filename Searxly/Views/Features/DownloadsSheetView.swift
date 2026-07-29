//
//  DownloadsSheetView.swift
//  Searxly
//
//  Now wired from ContentView (monster refactor). Previously unused duplicate removed.
//

import SwiftUI

struct DownloadsSheetView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack {
            Text("Downloads")
                .font(.title2.bold())
                .padding(.bottom)

            if AmnesiaMode.isActive {
                Text("Amnesic session: downloads vanish when you quit. Keep moves a file to your Downloads folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 4)
            }

            if DownloadsManager.shared.downloads.isEmpty {
                Text("No downloads yet")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(DownloadsManager.shared.downloads) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.suggestedFilename)
                                .font(.headline)
                            Text(item.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.isComplete, let url = item.destinationURL {
                            if item.isSessionOnly {
                                Button("Keep") {
                                    _ = DownloadsManager.shared.keepPermanently(id: item.id)
                                }
                                .help("Move to your Downloads folder so it survives this amnesic session")
                            }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            .help("Show in Finder")
                            Button("Open") {
                                // Searxly Maximum warns first — opening a downloaded file can leave Tor.
                                if AntiForensics.confirmOpenDownloadedFile(url) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
            }

            Button("Close") { isPresented = false }
                .padding(.top)
        }
        .padding()
        .frame(width: 420, height: 300)
    }
}
