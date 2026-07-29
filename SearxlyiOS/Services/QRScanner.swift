//
//  QRScanner.swift
//  SearxlyiOS
//
//  QR / barcode scanner for the address bar (VisionKit DataScanner — all recognition happens
//  on-device). A scanned URL opens as a page; any other payload runs as a search. One tap on a
//  recognized code confirms it; nothing is acted on automatically.
//

import SwiftUI
import VisionKit

/// Sheet wrapper: camera view when scanning is possible, honest fallbacks when not
/// (simulator, no camera, or camera access denied).
struct QRScannerSheet: View {
    /// Called with the scanned payload (URL string or plain text) after the user taps a code.
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private var appearance = AppearanceSettings.shared

    init(onScan: @escaping (String) -> Void) {
        self.onScan = onScan
    }

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    DataScannerRepresentable { payload in
                        Haptics.tap()
                        dismiss()
                        onScan(payload)
                    }
                    .ignoresSafeArea()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode.viewfinder")
                            .scaledFont(size: 40, weight: .light)
                            .foregroundStyle(Brand.textTertiary)
                        Text(DataScannerViewController.isSupported
                             ? L("Camera access is off. Allow it for Searxly in iOS Settings to scan codes.")
                             : L("Scanning isn't supported on this device."))
                            .scaledFont(size: 14)
                            .foregroundStyle(Brand.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Brand.bg.ignoresSafeArea())
                }
            }
            .navigationTitle(L("Scan Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .tint(Brand.text)
        }
        .preferredColorScheme(.dark)
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didTapOn item: RecognizedItem) {
            guard case .barcode(let barcode) = item,
                  let payload = barcode.payloadStringValue,
                  !payload.isEmpty else { return }
            onScan(payload)
        }
    }
}
