//
//  HeaderExtensionBubbles.swift
//  Searxly
//
//  Extension action buttons, just left of the address bar. Each installed extension that has a clickable
//  popup (Bitwarden, uBlock Origin Lite, Dark Reader, …) or runs on the current page appears as a round
//  logo bubble — at most two, then a "+N". Clicking a bubble with a popup opens the extension's REAL
//  popup, presented by the engine (WKWebExtensionAction.popupPopover — which carries its messaging port
//  to the background, so the popup actually works). Clicking one without a popup opens a small manage
//  card (run-on-this-site toggle + Remove). Right-click any bubble for the manage menu.
//
//  Standard tabs only — the caller passes nil webView for Private/Onion, where extensions never run.
//

import SwiftUI
import WebKit

/// Holds the header cluster's live `NSView`, used as the anchor for the engine's popup NSPopover.
final class ExtensionAnchorBox { weak var view: NSView? }

struct HeaderExtensionBubbles: View {
    let webView: WKWebView?
    let currentURL: URL?

    @State private var items: [ExtensionHeaderItem] = []
    @State private var presentedItemID: String?     // manage-card popover (no-popup extensions)
    @State private var overflowOpen = false
    @State private var anchorBox = ExtensionAnchorBox()

    private let bubbleSize: CGFloat = 22
    private let maxBubbles = 2

    private var host: String { currentURL?.host ?? "" }

    var body: some View {
        cluster
            .background(ExtensionAnchorCapture(box: anchorBox))
            .onAppear {
                refresh()
                if #available(macOS 15.4, *) { ExtensionManager.shared.fallbackPopoverAnchor = anchorBox.view }
            }
            .onChange(of: currentURL) { _, _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .laneAExtensionsChanged)) { _ in refresh() }
    }

    @ViewBuilder private var cluster: some View {
        if #available(macOS 15.4, *), ExtensionFeatures.programEnabled, !items.isEmpty {
            let shown = Array(items.prefix(maxBubbles))
            let overflow = Array(items.dropFirst(maxBubbles))
            HStack(spacing: -5) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    bubble(item).zIndex(Double(maxBubbles - index))
                }
                if !overflow.isEmpty {
                    overflowBubble(count: overflow.count, items: overflow)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    // MARK: - Bubbles

    private func bubble(_ item: ExtensionHeaderItem) -> some View {
        Button {
            openBubble(item.id)
        } label: {
            iconView(item)
        }
        .buttonStyle(.plain)
        .help(item.presentsPopup ? "Open \(item.displayName)" : item.displayName)
        .contextMenu { manageMenu(item) }
        // Only the manage card uses a SwiftUI popover; popups are presented natively by the engine.
        .popover(isPresented: presentedBinding(item.id), arrowEdge: .bottom) {
            manageCard(item)
        }
    }

    private func overflowBubble(count: Int, items overflow: [ExtensionHeaderItem]) -> some View {
        Button {
            overflowOpen = true
        } label: {
            Text("+\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: bubbleSize, height: bubbleSize)
                .background(.quaternary, in: Circle())
                .overlay(Circle().strokeBorder(ringColor, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help("\(count) more extension(s)")
        .popover(isPresented: $overflowOpen, arrowEdge: .bottom) {
            overflowList(overflow)
        }
    }

    private func iconView(_ item: ExtensionHeaderItem) -> some View {
        Group {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                    .frame(width: bubbleSize - 8, height: bubbleSize - 8)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: bubbleSize, height: bubbleSize)
        .background(.background, in: Circle())
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ringColor, lineWidth: 1.5))
        .overlay(alignment: .topTrailing) { badge(item) }
    }

    @ViewBuilder private func badge(_ item: ExtensionHeaderItem) -> some View {
        if item.healthWarning != nil {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(ringColor, lineWidth: 1))
        } else if !item.badgeText.isEmpty {
            Text(item.badgeText)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 2).frame(minWidth: 10, minHeight: 10)
                .background(Color.red, in: Capsule())
                .overlay(Capsule().strokeBorder(ringColor, lineWidth: 1))
                .offset(x: 3, y: -3)
        }
    }

    private var ringColor: Color { Color(nsColor: .windowBackgroundColor) }

    // MARK: - Manage card / overflow

    private func manageCard(_ item: ExtensionHeaderItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName).font(.system(size: 12.5, weight: .semibold))
                    Text(subtitle(item)).font(.system(size: 10.5))
                        .foregroundStyle(item.healthWarning != nil ? Color.orange : .secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !host.isEmpty {
                Toggle("Run on this site", isOn: siteEnabledBinding(item))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11.5))
            }
            Divider()
            HStack(spacing: 12) {
                Button { presentedItemID = nil; openSettings() } label: {
                    Label("Manage", systemImage: "gearshape").font(.system(size: 11.5))
                }.buttonStyle(.plain)
                Spacer()
                Button(role: .destructive) { remove(item) } label: {
                    Label("Remove", systemImage: "trash").font(.system(size: 11.5))
                }.buttonStyle(.plain).foregroundStyle(.red)
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 230, alignment: .leading)
    }

    private func overflowList(_ overflow: [ExtensionHeaderItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Extensions").font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider()
            ForEach(overflow) { item in
                HStack(spacing: 10) {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Text(item.displayName).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 6)
                    if item.presentsPopup {
                        Button {
                            overflowOpen = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { openBubble(item.id) }
                        } label: {
                            Text("Open").font(.system(size: 11, weight: .semibold))
                        }.buttonStyle(.plain).foregroundStyle(.blue)
                    }
                    Button(role: .destructive) { remove(item) } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                if item.id != overflow.last?.id { Divider().padding(.leading, 44) }
            }
        }
        .frame(width: 260)
    }

    @ViewBuilder private func manageMenu(_ item: ExtensionHeaderItem) -> some View {
        if item.presentsPopup {
            Button("Open \(item.displayName)") { openBubble(item.id) }
        }
        if !host.isEmpty {
            let on = ExtensionSiteStore.isEnabled(extensionID: item.id, host: host)
            Button(on ? "Turn off on \(host)" : "Turn on on \(host)") {
                if #available(macOS 15.4, *) {
                    ExtensionManager.shared.setExtensionEnabled(!on, extensionID: item.id, forHost: host)
                }
            }
        }
        Button("Manage in Settings") { openSettings() }
        Divider()
        Button("Remove \(item.displayName)", role: .destructive) { remove(item) }
    }

    private func subtitle(_ item: ExtensionHeaderItem) -> String {
        if let warning = item.healthWarning { return warning }
        if !host.isEmpty, !ExtensionSiteStore.isEnabled(extensionID: item.id, host: host) {
            return "Paused on this site"
        }
        return "Running on this site"
    }

    // MARK: - Actions

    private func presentedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { presentedItemID == id },
            set: { if !$0, presentedItemID == id { presentedItemID = nil } }
        )
    }

    private func openBubble(_ id: String) {
        guard let item = items.first(where: { $0.id == id }), let wv = webView, #available(macOS 15.4, *) else { return }
        if item.presentsPopup {
            // Native presentation: performAction → the delegate shows the engine's popupPopover anchored
            // to the cluster. This is what wires the popup's messaging to the background.
            guard let anchor = anchorBox.view else { return }
            ExtensionManager.shared.activateAction(extensionID: id, for: wv, relativeTo: anchor)
        } else {
            presentedItemID = id
        }
    }

    private func refresh() {
        guard #available(macOS 15.4, *), ExtensionFeatures.laneAEnabled,
              let webView, let scheme = currentURL?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            items = []
            return
        }
        // Ensure the extension engine treats the visible tab as active before a popup queries tab state.
        ExtensionManager.shared.setActiveTab(webView)
        ExtensionManager.shared.fallbackPopoverAnchor = anchorBox.view
        items = ExtensionManager.shared.headerItems(for: webView)
        if let presented = presentedItemID, !items.contains(where: { $0.id == presented }) {
            presentedItemID = nil
        }
    }

    private func siteEnabledBinding(_ item: ExtensionHeaderItem) -> Binding<Bool> {
        Binding(
            get: { host.isEmpty || ExtensionSiteStore.isEnabled(extensionID: item.id, host: host) },
            set: { enabled in
                guard #available(macOS 15.4, *), !host.isEmpty else { return }
                ExtensionManager.shared.setExtensionEnabled(enabled, extensionID: item.id, forHost: host)
            }
        )
    }

    private func remove(_ item: ExtensionHeaderItem) {
        guard #available(macOS 15.4, *) else { return }
        presentedItemID = nil
        overflowOpen = false
        ExtensionManager.shared.uninstall(extensionID: item.id)
        refresh()
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .showExtensionsTabRequested, object: nil)
    }
}

/// Captures the header cluster's `NSView` so the engine's popup NSPopover can anchor to it.
private struct ExtensionAnchorCapture: NSViewRepresentable {
    let box: ExtensionAnchorBox
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}
