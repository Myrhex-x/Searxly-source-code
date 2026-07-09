//
//  DownloadsView.swift
//  SearxlyiOS
//
//  The Downloads sheet: in-progress transfers with live progress on top, finished files below with a
//  native Quick Look preview on tap, share / Save to Files, and swipe-to-delete. Files never leave the
//  sandbox unless the user shares them. Monochrome, matching the rest of the app.
//

import SwiftUI
import QuickLook

struct DownloadsView: View {
    @Bindable private var manager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if manager.active.isEmpty && manager.completed.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(L("Downloads"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !manager.completed.isEmpty {
                        Button(L("Clear")) { withAnimation { manager.clearCompleted() } }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .tint(Brand.text)
        }
    }

    private var list: some View {
        List {
            if !manager.active.isEmpty {
                Section(L("In Progress")) {
                    ForEach(manager.active) { item in
                        ActiveRow(item: item) { manager.removeActive(item.id) }
                            .listRowBackground(Brand.surface)
                    }
                }
            }
            if !manager.completed.isEmpty {
                Section(L("On This Device")) {
                    ForEach(manager.completed) { item in
                        Button { previewURL = manager.fileURL(for: item) } label: {
                            CompletedRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Brand.surface)
                        .contextMenu {
                            ShareLink(item: manager.fileURL(for: item)) {
                                Label(L("Share…"), systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) { manager.removeCompleted(item) } label: {
                                Label(L("Delete"), systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { manager.removeCompleted(item) } label: {
                                Label(L("Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg)
        .quickLookPreview($previewURL)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .scaledFont(size: 42, weight: .light)
                .foregroundStyle(Brand.textTertiary)
            Text(L("No downloads yet"))
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(Brand.text)
            Text(L("Files you download stay on this device, in Searxly. Share them to save elsewhere."))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.textSecondary)
                .padding(.horizontal, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.bg)
    }
}

// MARK: - Rows

private struct ActiveRow: View {
    let item: DownloadManager.Active
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.failed ? "exclamationmark.circle" : "arrow.down.circle")
                .scaledFont(size: 26, weight: .light)
                .foregroundStyle(item.failed ? Brand.liveRed : Brand.textSecondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.filename)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(Brand.text)
                    .lineLimit(1)
                if item.failed {
                    Text(L("Download failed"))
                        .scaledFont(size: 12)
                        .foregroundStyle(Brand.liveRed)
                } else {
                    ProgressView(value: item.fraction)
                        .tint(Brand.text)
                    Text(progressLabel)
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Brand.textTertiary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 6)
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 20)
                    .foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.failed ? L("Dismiss") : L("Cancel"))
        }
        .padding(.vertical, 4)
    }

    private var progressLabel: String {
        let written = ByteCountFormatter.string(fromByteCount: item.bytesWritten, countStyle: .file)
        if item.totalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
            return "\(written) / \(total)"
        }
        return written
    }
}

private struct CompletedRow: View {
    let item: DownloadManager.Completed

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon(for: item.filename))
                .scaledFont(size: 24, weight: .regular)
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(Brand.text)
                    .lineLimit(1)
                Text(meta)
                    .scaledFont(size: 12)
                    .foregroundStyle(Brand.textTertiary)
            }
            Spacer(minLength: 6)
            Image(systemName: "eye")
                .scaledFont(size: 14)
                .foregroundStyle(Brand.textTertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var meta: String {
        let size = ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
        let date = item.finishedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(size) · \(date)"
    }

    /// A representative SF Symbol for the file type.
    static func icon(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "rar", "7z": return "doc.zipper"
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "svg": return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv", "webm": return "film"
        case "mp3", "aac", "wav", "flac", "m4a": return "music.note"
        case "dmg", "pkg", "exe", "msi", "app", "deb", "iso": return "shippingbox"
        case "csv", "xlsx", "numbers": return "tablecells"
        case "doc", "docx", "pages", "txt", "rtf", "md": return "doc.text"
        default: return "doc"
        }
    }
}
