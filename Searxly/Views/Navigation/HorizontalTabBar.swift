//
//  HorizontalTabBar.swift
//  Searxly
//
//  Extracted horizontal tab bar to keep ContentView manageable and to prepare
//  for per-tab privacy indicators (private tab badge, different styling, etc.).
//

import SwiftUI
import WebKit  // For BrowserTab.webView.url access in onSelect

struct HorizontalTabBar: View {
    @Binding var tabs: [BrowserTab]
    @Binding var selectedTabID: UUID?
    @Binding var searchText: String
    @Binding var showingWebContent: Bool
    @Binding var hoveredTabID: UUID?

    let glassEnabled: Bool
    let toolbarMaterial: Material

    let newTabAction: () -> Void
    let newPrivateTabAction: () -> Void
    let closeTabAction: (BrowserTab) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs) { tab in
                    TabButton(
                        tab: tab,
                        isSelected: selectedTabID == tab.id,
                        isHovered: hoveredTabID == tab.id,
                        glassEnabled: glassEnabled,
                        toolbarMaterial: toolbarMaterial,
                        style: .horizontalGlass,
                        onSelect: {
                            selectedTabID = tab.id
                            if let u = tab.currentURL ?? tab.webView?.url {
                                searchText = u.absoluteString
                                showingWebContent = true
                            } else {
                                showingWebContent = false
                            }
                        },
                        onClose: {
                            closeTabAction(tab)
                        }
                    )
                    .onHover { hovering in
                        hoveredTabID = hovering ? tab.id : nil
                    }
                }

                // New Tab Button. ⌘T / ⌘⇧T are File-menu commands (SearxlyApp) so they work over a
                // focused web page; this button is the pointer path only, no shortcut of its own.
                Button(action: newTabAction) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(8)
                }
                .buttonStyle(.plain)
                .background(toolbarMaterial, in: Circle())
                .searxlyGlass(glassEnabled ? .interactive : .clear, in: Circle())
                .padding(.leading, 4)
                .help("New Tab (⌘T)")
                .accessibilityLabel(Text("New Tab"))
            }
            .padding(.horizontal, 48)
        }
        .padding(.top, 6)
    }
}
