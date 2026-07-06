//
//  InAppNotificationBanner.swift
//  Searxly
//
//  Individual liquid-glass in-app notification toast.
//  - Fluid entry/exit (spring + move + opacity)
//  - Swipe to dismiss (horizontal drag for natural feel)
//  - Full glass integration using the app's existing glassEnabled + toolbarMaterial
//  - Matches the calm, minimal, high-quality aesthetic of the rest of the UI (onboarding cards, glassy buttons, etc.)
//  - Tap anywhere (except close) to "interact" (demo: just dismisses with a little emphasis)
//

import SwiftUI
import os

struct InAppNotificationBanner: View {
    let notification: AppNotification
    let glassEnabled: Bool
    let toolbarMaterial: Material

    var onDismiss: () -> Void
    var onInteract: () -> Void = {}

    @State private var dragOffset: CGFloat = 0
    @State private var isPressing = false

    private var effectiveMaterial: Material {
        glassEnabled ? toolbarMaterial : .ultraThinMaterial
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Left icon — glassy circular treatment to match other icon buttons in the app.
            ZStack {
                Circle()
                    .fill(Color.white.opacity(glassEnabled ? 0.08 : 0.06))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(glassEnabled ? 0.12 : 0.08), lineWidth: 1)
                    )

                Image(systemName: notification.iconSystemName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .searxlyGlass(glassEnabled ? .interactive : .clear, in: Circle())

            // Content
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(notification.source)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.8))

                    Text("·")
                        .foregroundStyle(Color.white.opacity(0.3))
                        .font(.caption)

                    Text("now")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))

                    Spacer(minLength: 4)

                    // Close button — small, high hit target, glassy.
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            onDismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 16, height: 16)
                    )
                    .searxlyGlass(.clear, in: Circle())
                    .help("Dismiss")
                }

                Text(notification.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(notification.body)
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(width: 320, alignment: .leading)
        // Liquid glass card treatment — exactly in the spirit of the rest of Searxly.
        .background(effectiveMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .searxlyGlass(glassEnabled ? .interactive : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(glassEnabled ? 0.09 : 0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
        .offset(x: dragOffset)
        .scaleEffect(isPressing ? 0.985 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isPressing)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        // Whole banner is interactive (tap to "view" the notification — demo just dismisses).
        .onTapGesture {
            onInteract()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                onDismiss()
            }
        }
        // Fluid horizontal swipe-to-dismiss (very macOS-notification-like).
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Only allow rightward or leftward dismiss; bias toward natural "push away".
                    let translation = value.translation.width
                    dragOffset = max(-40, min(160, translation * 0.9))
                }
                .onEnded { value in
                    let threshold: CGFloat = 70
                    let velocity = value.velocity.width

                    if dragOffset > threshold || velocity > 300 {
                        // Dismiss to the right with nice spring.
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            dragOffset = 220
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            onDismiss()
                            dragOffset = 0
                        }
                    } else {
                        // Snap back fluidly.
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .transition(
            .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        )
    }
}

#Preview {
    VStack(spacing: 12) {
        InAppNotificationBanner(
            notification: AppNotification(
                title: "New reply from @alice",
                body: "Hey, loved your take on the new SearXNG release — check this out!",
                source: "X",
                iconSystemName: "at.circle.fill"
            ),
            glassEnabled: true,
            toolbarMaterial: .regular
        ) {
            Log.app.info("dismiss")
        }

        InAppNotificationBanner(
            notification: AppNotification(
                title: "Download complete",
                body: "report-q2-2026.pdf finished downloading.",
                source: "Downloads",
                iconSystemName: "arrow.down.circle.fill"
            ),
            glassEnabled: false,
            toolbarMaterial: .regular
        ) {
            Log.app.info("dismiss")
        }
    }
    .padding()
    .background(Color.black)
}