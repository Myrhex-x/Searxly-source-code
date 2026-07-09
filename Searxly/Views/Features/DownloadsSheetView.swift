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
