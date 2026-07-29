//
//  AnswerEngineManager.swift
//  Searxly — Answer Engine
//
//  Persisted config + connection state for Searxly's built-in answer engine (the "Ask Searxly" panel).
//  The engine is OFF by default; the user turns it on and points it at their own local model. Nothing
//  here reaches the network except a loopback call to that model server.
//

import Foundation
import Observation

@MainActor
@Observable
final class AnswerEngineManager {
    static let shared = AnswerEngineManager()

    private static let enabledKey = "Searxly.AnswerEngine.Enabled"
    private static let providerKey = "Searxly.AnswerEngine.Provider"
    private static let baseURLKey = "Searxly.AnswerEngine.CustomBaseURL"
    private static let modelKey = "Searxly.AnswerEngine.Model"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    var provider: LocalModelProvider {
        didSet {
            guard oldValue != provider else { return }
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            availableModels = []
            connection = .unknown
        }
    }
    /// Empty ⇒ use the provider's default loopback URL.
    var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: Self.baseURLKey) }
    }
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }

    private(set) var availableModels: [String] = []

    enum Connection: Equatable {
        case unknown, checking, ok, failed(String)
    }
    private(set) var connection: Connection = .unknown

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let providerRaw = UserDefaults.standard.string(forKey: Self.providerKey) ?? LocalModelProvider.ollama.rawValue
        provider = LocalModelProvider(rawValue: providerRaw) ?? .ollama
        customBaseURL = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? ""
        model = UserDefaults.standard.string(forKey: Self.modelKey) ?? ""
    }

    /// The effective base URL: the custom override if set, else the provider default.
    var baseURL: String {
        let trimmed = customBaseURL.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? provider.defaultBaseURL : trimmed
    }

    var isConfigured: Bool { isEnabled && !model.isEmpty }

    func client() -> LocalModelClient { LocalModelClient(baseURL: baseURL, model: model) }

    /// Probe the local server: is it up, and what models does it serve? Auto-selects a model if none set.
    func checkConnection() {
        Task { await checkConnectionAsync() }
    }

    func checkConnectionAsync() async {
        connection = .checking
        let probe = LocalModelClient(baseURL: baseURL, model: model)
        guard await probe.reachable() else {
            availableModels = []
            connection = .failed("No local model server at \(baseURL). \(provider.setupHint)")
            return
        }
        let models = await probe.fetchModels()
        availableModels = models
        if model.isEmpty, let first = models.first { model = first }
        connection = models.isEmpty
            ? .failed("The server is running but has no model loaded. \(provider.setupHint)")
            : .ok
    }
}
