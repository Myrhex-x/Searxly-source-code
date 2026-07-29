//
//  OnboardingFilm.swift
//  SearxlyiOS
//
//  First-run as a short film. Six acts on pure black — title, shields, private search,
//  Apple Intelligence, yours, creed — that play themselves like a trailer: a story rail up top
//  fills in real time, tap advances, the left edge rewinds, holding a finger down pauses the
//  projector. The stage underneath is a night-side horizon, drifting dust, and a whisper of
//  projector flicker. Claims stay accurate to the iOS product only: hosted private search,
//  on-device shields, Apple Intelligence, encrypted local data — no wallet/VPN/local-SearXNG.
//
//  Reduce Motion (or VoiceOver) turns the film into stills: no auto-advance, no ambient motion,
//  every act rendered in its final state with the Continue button doing the walking.
//

import SwiftUI

extension Notification.Name {
    /// Posted when Settings asks to show the onboarding film again.
    static let searxlyReplayOnboarding = Notification.Name("searxly.replayOnboarding")
}

@MainActor
enum OnboardingGate {
    /// v2 — the film replaced the tap-through cinema, so existing installs see the new cut once.
    private static let key = "searxly.ios.onboarding.completed.v2"

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Clears completion and asks the root shell to present the film (Settings → Replay).
    static func requestReplay() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: .searxlyReplayOnboarding, object: nil)
    }

    #if DEBUG
    static func resetForDebug() {
        UserDefaults.standard.removeObject(forKey: key)
    }
    #endif
}

// MARK: - Film

struct OnboardingFilmView: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @State private var act = 0
    /// 0…1 fill of the current story-rail segment; the projector loop drives it.
    @State private var actProgress: Double = 0
    /// Finger down anywhere = projector paused (stories convention).
    @State private var paused = false
    @State private var finishFlash = false

    private static let actCount = 6
    /// Seconds each act plays before auto-advancing; the creed waits for the button.
    private static let runtimes: [Double] = [5.5, 7.5, 8.0, 7.0, 7.5, .infinity]

    /// Stills mode for Reduce Motion / VoiceOver — the film only moves when asked to.
    private var live: Bool { !reduceMotion && !voiceOver }
    private var autoAdvances: Bool { live && act < Self.actCount - 1 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                FilmStage(act: act, live: live)

                // Dedicated hit-layer for story navigation, deliberately BELOW the chrome so a
                // tap on Skip/Continue can only ever reach the button — never double-fire here.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(navigationGesture(width: geo.size.width))

                VStack(spacing: 0) {
                    topChrome
                    Spacer(minLength: 8)
                    actStage
                        .padding(.horizontal, 30)
                        // Acts are pure scenery until the creed brings its own buttons; letting
                        // touches fall through them keeps tap-anywhere navigation honest.
                        .allowsHitTesting(act == Self.actCount - 1)
                    Spacer(minLength: 8)
                    // One-time discoverability hint on the title card; after that the film is
                    // pure touch — tap ahead, left edge back, hold to pause. The creed brings
                    // its own buttons. Constant height so the stage never jumps between acts.
                    TapHint(visible: act == 0, live: live)
                        .padding(.bottom, 28)
                }

                CinemaFrame(visible: act == 0 || act == Self.actCount - 1)

                // White flash on exit into the app.
                if finishFlash {
                    Color.white.opacity(0.12)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task(id: act) { await runProjector() }
    }

    // MARK: - Chrome

    private var topChrome: some View {
        VStack(spacing: 10) {
            FilmRail(actCount: Self.actCount, act: act, fill: actProgress)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            HStack {
                // Tiny brand mark once past the title card (the stage owns the logo on act 0).
                if act > 0 {
                    Text(verbatim: "SEARXLY")
                        .font(.system(size: 10, weight: .black))
                        .tracking(2.4)
                        .foregroundStyle(Color.white.opacity(0.28))
                        .transition(.opacity)
                }
                Spacer()
                if act < Self.actCount - 1 {
                    Button(L("Skip")) { finish() }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 32)
            .animation(.easeOut(duration: 0.25), value: act)
        }
    }

    // MARK: - Acts

    @ViewBuilder
    private var actStage: some View {
        Group {
            switch act {
            case 0: TitleAct(live: live, onAdvance: advance)
            case 1: ShieldsAct(live: live, onAdvance: advance)
            case 2: SearchAct(live: live, onAdvance: advance)
            case 3: IntelligenceAct(live: live, onAdvance: advance)
            case 4: YoursAct(live: live, onAdvance: advance)
            default: FinaleAct(live: live, onStart: finish, onReplay: { goTo(0) })
            }
        }
        .id(act)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 16)),
            removal: .opacity.combined(with: .offset(y: -12))
        ))
        .frame(maxWidth: .infinity)
        .accessibilityActions {
            if act > 0 {
                Button(L("Go back")) { retreat() }
            }
        }
    }

    // MARK: - Projector

    /// Fills the current rail segment in real time and auto-advances when the act's runtime is
    /// up. `.task(id: act)` cancels and restarts this on every act change, so manual navigation
    /// never races the timer.
    private func runProjector() async {
        guard autoAdvances else {
            actProgress = 1
            return
        }
        actProgress = 0
        let runtime = Self.runtimes[act]
        while actProgress < 1 {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
            if !paused {
                actProgress = min(1, actProgress + 0.05 / runtime)
            }
        }
        advance()
    }

    /// Touch-down pauses, release navigates: left edge rewinds, anywhere else advances,
    /// horizontal swipes work in both directions. Buttons above still win hit-testing.
    private func navigationGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in paused = true }
            .onEnded { value in
                paused = false
                let dx = value.translation.width
                if dx < -56 { advance(); return }
                if dx > 56 { retreat(); return }
                guard abs(dx) < 24, abs(value.translation.height) < 24 else { return }
                if value.location.x < width * 0.22 { retreat() } else { advance() }
            }
    }

    private func advance() {
        guard act < Self.actCount - 1 else { return }
        Haptics.tick()
        goTo(act + 1)
    }

    private func retreat() {
        guard act > 0 else { return }
        Haptics.tick()
        goTo(act - 1)
    }

    private func goTo(_ index: Int) {
        actProgress = 0
        withAnimation(live ? .easeInOut(duration: 0.32) : nil) { act = index }
    }

    private func finish() {
        Haptics.success()
        OnboardingGate.markCompleted()
        guard live else {
            onFinished()
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { finishFlash = true }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            onFinished()
        }
    }
}

// MARK: - Story rail

/// Segmented film-strip progress: played acts full, current act filling in real time.
private struct FilmRail: View {
    let actCount: Int
    let act: Int
    let fill: Double

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<actCount, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: geo.size.width * segmentFill(i))
                        }
                    }
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private func segmentFill(_ i: Int) -> CGFloat {
        if i < act { return 1 }
        if i > act { return 0 }
        return CGFloat(fill)
    }
}

/// "Tap to continue", whispered once during the title card, then never again — the film trusts
/// the stories grammar after that. Fixed height so its arrival never shifts the stage.
private struct TapHint: View {
    let visible: Bool
    let live: Bool
    @State private var shown = false
    @State private var pulse = false

    var body: some View {
        Text(L("Tap to continue"))
            .font(.system(size: 12, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(Color.white.opacity(pulse ? 0.5 : 0.28))
            .opacity(shown && visible ? 1 : 0)
            .frame(height: 40)
            .accessibilityHidden(true)
            .task(id: visible) {
                guard visible else {
                    shown = false
                    return
                }
                guard live else {
                    shown = true
                    return
                }
                try? await Task.sleep(for: .seconds(2.6))
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.8)) { shown = true }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Stage

/// Everything behind the acts: night-side horizon low in the frame, dust drifting up through
/// the projector beam, a whisper of flicker, and the vignette that makes it a movie.
private struct FilmStage: View {
    let act: Int
    let live: Bool

    var body: some View {
        ZStack {
            HorizonLight(act: act, live: live)
            DustField(active: live)
            if live { ProjectorFlicker() }

            RadialGradient(
                colors: [.clear, Color.black.opacity(0.6)],
                center: .center,
                startRadius: 150,
                endRadius: 560
            )
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

/// A planet-limb arc of light along the bottom of the frame — the night side of somewhere,
/// breathing slowly, sinking a few points deeper with every act.
private struct HorizonLight: View {
    let act: Int
    let live: Bool
    @State private var breathe = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Atmosphere glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(breathe ? 0.11 : 0.075),
                                Color.white.opacity(0.02),
                                .clear
                            ],
                            center: .center,
                            startRadius: w * 0.55,
                            endRadius: w * 1.1
                        )
                    )
                    .frame(width: w * 2.2, height: w * 2.2)
                    .position(x: w / 2, y: h + w * 0.78)

                // Crisp limb line
                Circle()
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                    .frame(width: w * 2.0, height: w * 2.0)
                    .position(x: w / 2, y: h + w * 0.78)
            }
            .offset(y: CGFloat(act) * 7)
            .animation(.easeInOut(duration: 0.6), value: act)
        }
        .ignoresSafeArea()
        .onAppear {
            guard live else { return }
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

/// Sparse dust motes rising through the frame. Low count + 8 fps keeps the GPU bill tiny
/// (the old cinema learned that full-rate ambient burned battery).
private struct DustField: View {
    let active: Bool

    private struct Mote {
        let x: CGFloat, y0: CGFloat, s: CGFloat, v: Double, p: Double
    }

    private let motes: [Mote] = {
        (0..<26).map { i in
            var rng = FilmSeed(UInt64(i) &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1CE)
            return Mote(
                x: CGFloat.random(in: 0...1, using: &rng),
                y0: CGFloat.random(in: 0...1, using: &rng),
                s: CGFloat.random(in: 0.6...1.8, using: &rng),
                v: Double.random(in: 0.008...0.024, using: &rng),
                p: Double.random(in: 0...(2 * .pi), using: &rng)
            )
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 8.0 : 120)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for m in motes {
                    var y = active
                        ? (m.y0 - CGFloat((t * m.v).truncatingRemainder(dividingBy: 1)))
                        : m.y0
                    if y < 0 { y += 1 }
                    let sway = active ? CGFloat(sin(t * 0.3 + m.p)) * 4 : 0
                    let tw = active
                        ? 0.05 + 0.13 * (0.5 + 0.5 * sin(t * (0.4 + m.v * 8) + m.p))
                        : 0.1
                    let r = CGRect(
                        x: m.x * size.width + sway,
                        y: y * size.height,
                        width: m.s,
                        height: m.s
                    )
                    ctx.fill(Path(ellipseIn: r), with: .color(.white.opacity(tw)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// One full-screen veil whose opacity wanders a hair at 6 fps — projector flicker at the
/// threshold of perception.
private struct ProjectorFlicker: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 6.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let a = 0.010 + 0.008 * (0.5 + 0.5 * sin(t * 5.1) * sin(t * 1.7 + 1.3))
            Color.white.opacity(a)
                .ignoresSafeArea()
                .blendMode(.plusLighter)
        }
    }
}

/// Widescreen hairlines that frame the title card and the creed, then get out of the way.
private struct CinemaFrame: View {
    let visible: Bool

    var body: some View {
        VStack {
            frameEdge
            Spacer()
            frameEdge
        }
        .padding(.top, 74)
        .padding(.bottom, 106)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.6), value: visible)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var frameEdge: some View {
        LinearGradient(
            colors: [.clear, Color.white.opacity(0.14), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .padding(.horizontal, 34)
    }
}

// MARK: - Shared bits

struct FilmPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Deterministic RNG so the dust field is identical every run (and in previews).
struct FilmSeed: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
