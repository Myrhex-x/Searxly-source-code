//
//  PageInfoView.swift
//  SearxlyiOS
//
//  The panel behind the address pill's lock icon (Safari's page menu ∪ Brave's shields panel):
//  connection security, per-page tracker tally, the per-site shields toggle, remembered site
//  preferences (desktop mode / text size), and Brave-style "Shred" (erase this site's data).
//

import SwiftUI

struct PageInfoView: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var shredded = false
    private var locale = AppLocale.shared

    init(model: BrowserModel) {
        self.model = model
    }

    private var host: String { model.webView.url?.host ?? "" }
    private var displayHost: String { host.replacingOccurrences(of: "www.", with: "") }
    private var isSecure: Bool {
        model.webView.url?.scheme?.lowercased() == "https" && model.webView.hasOnlySecureContent
    }

    var body: some View {
        let _ = locale.languageCode
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        FaviconView(host: displayHost, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.pageTitle.isEmpty ? displayHost : model.pageTitle)
                                .scaledFont(size: 16, weight: .semibold)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Image(systemName: isSecure ? "lock.fill" : "lock.open")
                                    .scaledFont(size: 10, weight: .semibold)
                                Text(isSecure ? L("Connection is encrypted") : L("Connection is not fully secure"))
                                    .scaledFont(size: 12)
                            }
                            .foregroundStyle(isSecure ? Brand.textSecondary : Color.red)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    LabeledContent(L("Trackers blocked on this page"),
                                   value: "\(model.pageBlockedCount)")
                    Toggle(String(format: L("Shields for %@"), displayHost), isOn: shieldsBinding)
                        .tint(.green)
                } header: {
                    Text(L("Shields"))
                } footer: {
                    Text(L("Lowering shields turns off ad & tracker blocking for this site only (reloads the page)."))
                }

                Section {
                    Toggle(L("Request Desktop Website"), isOn: desktopBinding).tint(.green)
                    HStack {
                        Text(L("Text Size"))
                        Spacer()
                        Button { model.adjustTextZoom(-0.1) } label: {
                            Image(systemName: "textformat.size.smaller").frame(width: 34, height: 26)
                        }
                        .buttonStyle(.bordered)
                        Text("\(Int((model.textZoom * 100).rounded()))%")
                            .scaledFont(size: 13, weight: .medium).monospacedDigit()
                            .frame(width: 44)
                        Button { model.adjustTextZoom(0.1) } label: {
                            Image(systemName: "textformat.size.larger").frame(width: 34, height: 26)
                        }
                        .buttonStyle(.bordered)
                    }
                } header: {
                    Text(L("Site Settings"))
                } footer: {
                    Text(String(format: L("Remembered for %@ — pages on this site always load this way."), displayHost))
                }

                Section {
                    Button(shredded ? L("Site Data Erased") : L("Erase Site Data & Reload"), role: .destructive) {
                        model.shredCurrentSite()
                        shredded = true
                    }
                    .disabled(shredded)
                } footer: {
                    Text(String(format: L("Deletes cookies, caches, and storage that %@ keeps on this device, then reloads it signed out and fresh."), displayHost))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(L("Page Info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .tint(Brand.text)
            .preferredColorScheme(.dark)
        }
        .presentationDetents([.medium, .large])
    }

    private var shieldsBinding: Binding<Bool> {
        Binding(
            get: { model.shieldsOnForCurrentSite },
            set: { _ in
                model.toggleShieldsForCurrentSite()
                dismiss()
            }
        )
    }

    private var desktopBinding: Binding<Bool> {
        Binding(
            get: { model.isDesktopSite },
            set: { _ in
                model.toggleDesktopSite()
                dismiss()
            }
        )
    }
}
