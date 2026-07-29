//
//  VoiceSearch.swift
//  SearxlyiOS
//
//  Voice search — strictly ON-DEVICE dictation (SFSpeechRecognizer with
//  `requiresOnDeviceRecognition`, so speech never leaves the device; languages whose on-device
//  model isn't installed surface as unavailable rather than silently going to a server).
//  The controller owns the audio engine + recognition task; VoiceSearchSheet is the UI.
//

import AVFoundation
import Speech
import SwiftUI
import Observation

@MainActor
@Observable
final class VoiceSearchController {

    enum Phase: Equatable {
        case idle
        case listening
        case denied          // mic or speech permission refused
        case unavailable     // no on-device recognition for this language
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""

    private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    /// The recognizer follows the app's content language, falling back to the system locale.
    private var recognizer: SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: SearchSettings.shared.resolvedContentLanguage))
            ?? SFSpeechRecognizer()
    }

    func start() async {
        guard phase != .listening else { return }
        transcript = ""

        // Permissions first (both prompts are one-time system dialogs).
        let speechAuth = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speechAuth == .authorized else { phase = .denied; return }
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else { phase = .denied; return }

        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            phase = .unavailable
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true   // the whole point
        request.shouldReportPartialResults = true
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil, self.phase == .listening, self.transcript.isEmpty {
                    // A start-of-session error with nothing heard yet reads as "didn't work".
                    self.stopEngine()
                    self.phase = .failed(L("Couldn't hear anything. Try again."))
                }
            }
        }
    }

    /// Stops listening and returns the final transcript (empty when nothing was recognized).
    func stop() -> String {
        stopEngine()
        phase = .idle
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        stopEngine()
        transcript = ""
        phase = .idle
    }

    private func stopEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Sheet

/// Listening UI: pulsing mic, live transcript, tap the mic (or Search) to run it.
struct VoiceSearchSheet: View {
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var controller = VoiceSearchController()
    @State private var pulse = false
    private var appearance = AppearanceSettings.shared

    init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(spacing: 22) {
            Capsule().fill(Brand.surfaceHi).frame(width: 36, height: 5).padding(.top, 10)
            Spacer(minLength: 0)

            switch controller.phase {
            case .denied:
                statusText(L("Searxly needs microphone and speech access for voice search. You can allow both in iOS Settings."))
            case .unavailable:
                statusText(L("On-device dictation isn't available for your language on this device."))
            case .failed(let message):
                statusText(message)
            case .idle, .listening:
                Text(controller.transcript.isEmpty
                     ? (controller.phase == .listening ? L("Listening…") : L("Preparing…"))
                     : controller.transcript)
                    .font(.system(size: 20 * appearance.textScale, weight: .medium))
                    .foregroundStyle(controller.transcript.isEmpty ? Brand.textTertiary : Brand.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
                    .animation(.easeOut(duration: 0.12), value: controller.transcript)
            }

            Spacer(minLength: 0)

            Button { finish() } label: {
                ZStack {
                    Circle()
                        .fill(Brand.text.opacity(0.08))
                        .frame(width: 84, height: 84)
                        .scaleEffect(pulse ? 1.12 : 1.0)
                    Circle()
                        .fill(Brand.text)
                        .frame(width: 66, height: 66)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Brand.bg)
                }
            }
            .buttonStyle(.plain)
            .disabled(controller.phase != .listening)
            .accessibilityLabel(L("Stop and search"))

            Text(L("Recognized on this device — your voice never leaves it."))
                .scaledFont(size: 11)
                .foregroundStyle(Brand.textTertiary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.bg.ignoresSafeArea())
        .presentationDetents([.medium])
        .task {
            await controller.start()
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onDisappear { controller.cancel() }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 14)
            .foregroundStyle(Brand.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 30)
    }

    private func finish() {
        let text = controller.stop()
        dismiss()
        if !text.isEmpty { onSubmit(text) }
    }
}
