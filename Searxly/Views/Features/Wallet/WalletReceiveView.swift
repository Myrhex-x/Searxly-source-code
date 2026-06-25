//
//  WalletReceiveView.swift
//  Searxly
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct WalletReceiveView: View {
    /// Pre-selects a coin in the asset chips (set when opened from a coin's detail). The address is the
    /// same across every EVM network regardless. nil → default.
    var initialTokenID: String? = nil
    @State private var wallet = WalletManager.shared
    @State private var copiedAddress = false
    @State private var selectedTokenID = "SEARXLY"

    private var address: String { wallet.activeAddress ?? "" }

    private var displayAddress: String {
        address.count == 42 ? address.lowercased() : address
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                // Plain-language intro so a newcomer knows what this screen is for.
                Text("Share your address to get paid. Scan the code or copy it below.")
                    .font(.system(size: 12))
                    .foregroundStyle(WalletTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)

                // Token selector — flat pill
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(wallet.visibleTokens) { token in
                            Button { selectedTokenID = token.id } label: {
                                HStack(spacing: 7) {
                                    TokenIconView(token: token, size: 18)
                                    Text(token.symbol)
                                        .font(.system(size: 12, weight: selectedTokenID == token.id ? .semibold : .regular))
                                        .foregroundStyle(selectedTokenID == token.id ? WalletTheme.textPrimary : WalletTheme.textTertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    selectedTokenID == token.id ? WalletTheme.surfaceSelected : Color.clear,
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(5)
                }
                .background(WalletTheme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(WalletTheme.hairline, lineWidth: 1))

                // QR code
                Group {
                    if let qrImage = generateQR(from: displayAddress, size: 200) {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .padding(16)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(WalletTheme.surface)
                            .frame(width: 200, height: 200)
                            .overlay(
                                VStack(spacing: 10) {
                                    Image(systemName: "qrcode")
                                        .font(.system(size: 38))
                                        .foregroundStyle(WalletTheme.textTertiary)
                                    Text("Address available\nafter wallet activation")
                                        .font(.system(size: 11))
                                        .foregroundStyle(WalletTheme.textTertiary)
                                        .multilineTextAlignment(.center)
                                }
                            )
                    }
                }

                // Address display
                VStack(spacing: 12) {
                    Text(address.isEmpty ? "0x — — — — — — — — — — — — — — — —"
                                        : formatted(displayAddress))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(address.isEmpty ? WalletTheme.textTertiary : WalletTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .walletGlass(radius: WalletTheme.radiusField, fill: WalletTheme.surfaceField)

                    Button {
                        guard !address.isEmpty else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                        withAnimation { copiedAddress = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { copiedAddress = false }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 12))
                            Text(copiedAddress ? "Copied!" : "Copy Address")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(copiedAddress ? WalletTheme.textSecondary : .white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(WalletTheme.surfaceStrong, in: Capsule())
                        .overlay(Capsule().strokeBorder(WalletTheme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(address.isEmpty)
                    .animation(.easeInOut(duration: 0.18), value: copiedAddress)
                }

                // Network note
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(WalletTheme.textTertiary)
                    Text("This address works for \(wallet.activeChain.nativeSymbol) and any coin on \(wallet.activeChain.name).\nOnly send coins on the \(wallet.activeChain.name) network here.")
                        .font(.system(size: 11))
                        .foregroundStyle(WalletTheme.textTertiary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 4)
            }
            .padding(22)
        }
        .onAppear { if let initialTokenID { selectedTokenID = initialTokenID } }
    }

    private func formatted(_ addr: String) -> String {
        guard addr.count == 42 else { return addr }
        let body = addr.dropFirst(2)
        let chunks = stride(from: 0, to: body.count, by: 4).map { i -> String in
            let s = body.index(body.startIndex, offsetBy: i)
            let e = body.index(s, offsetBy: min(4, body.count - i))
            return String(body[s..<e])
        }
        return "0x " + chunks.joined(separator: " ")
    }

    private func generateQR(from string: String, size: CGFloat) -> NSImage? {
        guard !string.isEmpty,
              string != "0x0000000000000000000000000000000000000000"
        else { return nil }
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}
