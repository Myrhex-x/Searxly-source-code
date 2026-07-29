//
//  SummarySheet.swift
//  SearxlyiOS
//
//  Streaming on-device page summary (Apple Intelligence): a Liquid Glass header card with the
//  page identity, the summary in a comfortable reading column, and glass capsule actions
//  (Copy / Regenerate) docked at the bottom. Monochrome throughout.
//

import SwiftUI
import UIKit

struct SummarySheet: View {
    /// What to summarize: the live page (text extracted from its webview) or an already-extracted
    /// reader article (Reader's Summarize button — no webview needed).
    private enum Source {
        case page(BrowserModel)
        case article(ReaderArticle)
    }
    private let source: Source
    @Environment(\.dismiss) private var dismiss

    private var appearance = AppearanceSettings.shared

    init(model: BrowserModel) {
        source = .page(model)
    }

    init(article: ReaderArticle) {
        source = .article(article)
    }

    private var displayTitle: String {
        switch source {
        case .page(let model):
            return model.pageTitle.isEmpty ? (model.webView.url?.host ?? "") : model.pageTitle
        case .article(let article):
            return article.title.isEmpty ? article.host : article.title
        }
    }

    private enum Phase: Equatable {
        case extracting, streaming, done, failed(String)
    }

    @State private var phase: Phase = .extracting
    @State private var summary = ""
    @State private var task: Task<Void, Never>?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    switch phase {
                    case .extracting:
                        loadingRow(L("Reading the page…"))
                    case .streaming, .done:
                        Text(summary.isEmpty ? "…" : summary)
                            .font(.system(size: 15 * appearance.textScale))
                            .lineSpacing(3.5)
                            .foregroundStyle(Brand.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if phase == .streaming { loadingRow(L("Summarizing…")) }
                    case .failed(let message):
                        Text(message)
                            .scaledFont(size: 14)
                            .foregroundStyle(Brand.textSecondary)
                    }

                    Color.clear.frame(height: 66)  // clearance for the docked action bar
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(L("Page Summary"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .tint(Brand.text)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Brand.bg)
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    /// Page identity on a Liquid Glass card: official Apple Intelligence mark, title, privacy line.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AppleIntelligenceBadge(iconSize: 15, diameter: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 15 * appearance.textScale, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .scaledFont(size: 9, weight: .semibold)
                    Text(L("Generated on this iPhone — the page never leaves your device."))
                        .scaledFont(size: 11)
                }
                .foregroundStyle(Brand.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .searxlyGlassCard(cornerRadius: 18)
    }

    /// Docked glass capsules: Copy + Regenerate.
    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = summary
                copied = true
                Haptics.tick()
            } label: {
                Label(copied ? L("Copied") : L("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(Brand.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .disabled(summary.isEmpty)
            .searxlyGlassCapsule()

            Button {
                copied = false
                start()
            } label: {
                Label(L("Regenerate"), systemImage: "arrow.clockwise")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(Brand.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .disabled(phase == .streaming || phase == .extracting)
            .searxlyGlassCapsule()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func loadingRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Brand.textTertiary)
            Text(label)
                .scaledFont(size: 13)
                .foregroundStyle(Brand.textTertiary)
        }
    }

    private func start() {
        task?.cancel()
        summary = ""
        phase = .extracting
        let title = displayTitle
        let source = self.source
        task = Task {
            let extracted: String?
            switch source {
            case .page(let model):
                extracted = await PageIntelligence.pageText(from: model.webView)
            case .article(let article):
                let text = article.blocks.map(\.text).joined(separator: "\n\n")
                extracted = text.count > 200 ? String(text.prefix(PageIntelligence.maxChars)) : nil
            }
            guard let text = extracted else {
                phase = .failed(L("There isn't enough readable text on this page to summarize."))
                return
            }
            guard !Task.isCancelled else { return }
            phase = .streaming
            do {
                for try await snapshot in PageIntelligence.summarize(title: title, text: text) {
                    guard !Task.isCancelled else { return }
                    summary = snapshot
                }
                phase = .done
            } catch {
                if !Task.isCancelled {
                    phase = summary.isEmpty ? .failed(PageIntelligence.friendlyError(error)) : .done
                }
            }
        }
    }
}
