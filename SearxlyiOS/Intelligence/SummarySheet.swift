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
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var appearance = AppearanceSettings.shared

    init(model: BrowserModel) {
        self.model = model
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
                            .font(.system(size: 15.5 * appearance.textScale))
                            .lineSpacing(3.5)
                            .foregroundStyle(Brand.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if phase == .streaming { loadingRow(L("Summarizing…")) }
                    case .failed(let message):
                        Text(message)
                            .font(.system(size: 14))
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

    /// Page identity on a Liquid Glass card: sparkles badge, title, host, privacy line.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.bg)
                .frame(width: 32, height: 32)
                .background(Brand.text, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(model.pageTitle.isEmpty ? (model.webView.url?.host ?? "") : model.pageTitle)
                    .font(.system(size: 15 * appearance.textScale, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text(L("Generated on this iPhone — the page never leaves your device."))
                        .font(.system(size: 11))
                }
                .foregroundStyle(Brand.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .glassEffect(.regular.tint(glassTint), in: .rect(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Brand.hairline, lineWidth: 0.5)
        )
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .disabled(summary.isEmpty)
            .glassEffect(.regular.tint(glassTint), in: .capsule)

            Button {
                copied = false
                start()
            } label: {
                Label(L("Regenerate"), systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .disabled(phase == .streaming || phase == .extracting)
            .glassEffect(.regular.tint(glassTint), in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var glassTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035)
    }

    private func loadingRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Brand.textTertiary)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Brand.textTertiary)
        }
    }

    private func start() {
        task?.cancel()
        summary = ""
        phase = .extracting
        let title = model.pageTitle
        task = Task {
            guard let text = await PageIntelligence.pageText(from: model.webView) else {
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
                    phase = summary.isEmpty ? .failed(error.localizedDescription) : .done
                }
            }
        }
    }
}
