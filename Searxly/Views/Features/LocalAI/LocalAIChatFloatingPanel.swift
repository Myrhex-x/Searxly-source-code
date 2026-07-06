//
//  LocalAIChatFloatingPanel.swift
//  Searxly
//
//  Extracted draggable floating panel presentation for Local AI Chat.
//  Owns the dimmed background, fixed-size glass panel, drag gesture (session-persistent offset),
//  and entrance/exit transitions.
//
//  The actual chat content (LocalAIChatSheet) is supplied by the caller so all the complex
//  tool closures and RAG wiring can stay close to BrowserState in ContentView.

import SwiftUI

struct LocalAIChatFloatingPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var isPresented: Bool
    let glassEnabled: Bool
    let content: Content

    // Draggable floating panel state (size is fixed to avoid layout breaks).
    // Position persists for the session (user can drag it); size is locked.
    @State private var panelOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    /// Fixed size chosen to be a little larger than the previous 680x560 default.
    private let fixedSize = CGSize(width: 720, height: 620)

    var body: some View {
        if isPresented {
            ZStack {
                // Dimmed background — tap outside to dismiss (modern, calm)
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture {
                        DispatchQueue.main.async {
                            isPresented = false
                        }
                    }

                // The main draggable (but non-resizable) chat panel
                content
                    .frame(width: fixedSize.width, height: fixedSize.height)
                    .background(
                        glassEnabled
                            ? .ultraThinMaterial
                            : .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(
                                AdaptiveChrome.border(colorScheme, dark: glassEnabled ? 0.08 : 0.05),
                                lineWidth: 0.8
                            )
                    )
                    .shadow(color: .black.opacity(glassEnabled ? 0.22 : 0.14), radius: 28, x: 0, y: 12)
                    .offset(
                        x: panelOffset.width + dragOffset.width,
                        y: panelOffset.height + dragOffset.height
                    )
                    // Whole-panel drag for moving
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragOffset = value.translation
                            }
                            .onEnded { value in
                                panelOffset.width += value.translation.width
                                panelOffset.height += value.translation.height
                                dragOffset = .zero
                            }
                    )
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.84), value: isPresented)
        }
    }
}