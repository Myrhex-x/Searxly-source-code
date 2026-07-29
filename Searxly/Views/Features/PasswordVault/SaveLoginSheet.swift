//
//  SaveLoginSheet.swift
//  Searxly
//

import SwiftUI

struct SaveLoginSheet: View {
    let domain: String
    var initialUsername: String = ""
    var initialPassword: String = ""
    let onCancel: () -> Void
    let onSaved: () -> Void

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var notes: String = ""
    @State private var showPassword = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var vault: PasswordVaultManager { PasswordVaultManager.shared }
    private var normalizedDomain: String {
        PasswordVaultManager.normalizeDomain(domain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save Login")
                    .font(.title2.weight(.semibold))

                Text("Store credentials for \(normalizedDomain.isEmpty ? "this site" : normalizedDomain) in your on-device vault.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                fieldRow("Username or email") {
                    TextField("username", text: $username)
                        .textFieldStyle(.roundedBorder)
                }

                fieldRow("Password") {
                    HStack(spacing: 8) {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                fieldRow("Notes (optional)") {
                    TextField("Optional note", text: $notes)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Not Now", role: .cancel) { onCancel() }
                    .buttonStyle(.bordered)

                Spacer()

                Button("Save to Vault") {
                    save()
                }
                .buttonStyle(.bordered)
                .disabled(isSaving || username.isEmpty || password.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 420)
        .onAppear {
            username = initialUsername
            password = initialPassword
        }
    }

    @ViewBuilder
    private func fieldRow<F: View>(_ title: String, @ViewBuilder content: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        let targetDomain = normalizedDomain.isEmpty ? domain : normalizedDomain
        if vault.addEntry(domain: targetDomain, username: username, password: password, notes: notes) != nil {
            onSaved()
        } else {
            errorMessage = "Could not save login."
            isSaving = false
        }
    }
}