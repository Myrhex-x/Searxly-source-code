//
//  AnswerEngineView.swift
//  Searxly — Answer Engine
//
//  The "Ask Searxly" panel: a Perplexity-style answer engine that runs on the user's own local model and
//  Searxly's private-web tools. Type a question → it searches, reads sources, and writes a cited answer,
//  with a live trace of every tool call. Presented as a sheet from ContentView.
//

import SwiftUI
import AppKit

struct AnswerEngineView: View {
    @Bindable private var manager = AnswerEngineManager.shared
    private var engine = AnswerEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showConfig = false
    @FocusState private var inputFocused: Bool

    /// Opens a citation in Searxly (wired by ContentView to a new tab), then closes the panel.
    var onOpenLink: (URL) -> Void = { NSWorkspace.shared.open($0) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !manager.isEnabled {
                enableCard
            } else {
                ScrollView { results.padding(20) }
                Divider()
                inputBar
            }
        }
        .frame(minWidth: 580, idealWidth: 680, minHeight: 540, idealHeight: 640)
        .onAppear {
            if manager.isEnabled && manager.connection == .unknown { manager.checkConnection() }
            inputFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 14, weight: .semibold))
            Text("Ask Searxly").font(.headline)
            Spacer(minLength: 8)
            if manager.isEnabled {
                connectionDot
                modelMenu
                Button { showConfig.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Model settings")
            }
            Button("Done") { dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { if showConfig && manager.isEnabled { EmptyView() } }
        .background(alignment: .bottom) { configPanel }
    }

    @ViewBuilder
    private var configPanel: some View {
        if showConfig && manager.isEnabled {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Model app", selection: $manager.provider) {
                    ForEach(LocalModelProvider.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: manager.provider) { _, _ in manager.checkConnection() }

                HStack {
                    TextField(manager.provider.defaultBaseURL, text: $manager.customBaseURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Check") { manager.checkConnection() }
                }
                if case .failed(let msg) = manager.connection {
                    Text(msg).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text(manager.provider.setupHint).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .offset(y: 140)
            .shadow(radius: 8, y: 4)
            .zIndex(10)
        }
    }

    private var connectionDot: some View {
        let (color, label): (Color, String) = {
            switch manager.connection {
            case .unknown:  return (.secondary, "Not checked")
            case .checking: return (.yellow, "Checking…")
            case .ok:       return (.green, "Connected")
            case .failed:   return (.red, "Offline")
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .help("Local model at \(manager.baseURL)")
    }

    private var modelMenu: some View {
        Menu {
            if manager.availableModels.isEmpty {
                Button("Check connection") { manager.checkConnection() }
            } else {
                ForEach(manager.availableModels, id: \.self) { m in
                    Button { manager.model = m } label: {
                        if m == manager.model { Label(m, systemImage: "checkmark") } else { Text(m) }
                    }
                }
            }
        } label: {
            Text(manager.model.isEmpty ? "Select model" : manager.model)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: 180)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Enable card

    private var enableCard: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 34, weight: .light))
            Text("Ask Searxly").font(.title2.weight(.semibold))
            Text("Answer questions with your own local model, grounded in the private web — searching and reading through Searxly's tools. Nothing leaves this Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Turn on the answer engine") {
                manager.isEnabled = true
                manager.checkConnection()
            }
            .buttonStyle(.borderedProminent)
            Text("You'll need a local model app running, like Ollama or LM Studio.")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if engine.question.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text(engine.question).font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if !engine.trace.isEmpty { traceView }

                switch engine.phase {
                case .searching, .reading, .thinking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(phaseLabel).font(.callout).foregroundStyle(.secondary)
                    }
                case .failed(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                case .done, .idle:
                    EmptyView()
                }

                if !engine.answer.isEmpty {
                    Text(rendered(engine.answer))
                        .font(.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !engine.citations.isEmpty { citationsView }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask anything").font(.title3.weight(.semibold))
            Text("Searxly will search and read the web with your local model, then answer with sources.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.examples, id: \.self) { ex in
                    Button { draft = ex; submit() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right").font(.caption)
                            Text(ex).font(.callout)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var traceView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(engine.trace) { step in
                HStack(spacing: 8) {
                    Image(systemName: step.ok ? iconFor(step.tool) : "xmark.circle")
                        .font(.caption).foregroundStyle(step.ok ? Color.secondary : Color.orange)
                    Text(labelFor(step.tool)).font(.caption.weight(.medium))
                    if !step.detail.isEmpty {
                        Text(step.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var citationsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources").font(.subheadline.weight(.semibold))
            ForEach(engine.citations) { c in
                Button { if let u = URL(string: c.url) { onOpenLink(u) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "link").font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title).font(.callout).lineLimit(1)
                            Text(URL(string: c.url)?.host ?? c.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask anything…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { submit() }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            if engine.isRunning {
                Button { engine.cancel() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.bordered)
                    .help("Stop")
            } else {
                Button { submit() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || !manager.isConfigured)
                    .help(manager.isConfigured ? "Ask" : "Choose a local model first")
            }
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func submit() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, manager.isConfigured else { return }
        engine.ask(q)
        draft = ""
    }

    private var phaseLabel: String {
        switch engine.phase {
        case .searching: return "Searching the web…"
        case .reading:   return "Reading sources…"
        case .thinking:  return "Thinking…"
        default:         return ""
        }
    }

    private func rendered(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    private func iconFor(_ tool: String) -> String {
        switch tool {
        case "web_search":       return "magnifyingglass"
        case "read_page":        return "doc.text"
        case "knowledge_lookup": return "book"
        default:                 return "wrench.and.screwdriver"
        }
    }
    private func labelFor(_ tool: String) -> String {
        switch tool {
        case "web_search":       return "Searched"
        case "read_page":        return "Read"
        case "knowledge_lookup": return "Looked up"
        default:                 return tool
        }
    }

    private static let examples = [
        "What changed in the latest macOS release?",
        "Compare Ollama and LM Studio for local models",
        "What is Model Context Protocol and why does it matter?"
    ]
}
