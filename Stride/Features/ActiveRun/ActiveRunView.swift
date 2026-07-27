import SwiftUI
import SwiftData
import UIKit

struct ActiveRunView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings

    // Both queries are filtered and sorted to match every other reader in the app.
    // Unfiltered, `activePlans.first` was whatever SwiftData returned — and since
    // finished plans are now retained as history, that was regularly a *past* plan,
    // so finishing a run re-derived paces for a completed block while the real
    // active plan was never refreshed (N3).
    @Query(sort: \UserProfile.updatedAt, order: .reverse)
    private var profiles: [UserProfile]
    @Query(
        filter: #Predicate<TrainingPlan> { $0.isActive },
        sort: \TrainingPlan.createdAt, order: .reverse
    )
    private var activePlans: [TrainingPlan]
    @State private var showFinishConfirmation = false
    @State private var saveErrorMessage: String?
    /// The finished run awaiting persistence, kept so a failed save can be retried
    /// without re-finishing the (one-shot) tracker.
    @State private var pendingSave: RunWorkout?
    @State private var recPulse = false
    @State private var heartPulse = false
    @State private var controlsAppeared = false
    @State private var metricsAppeared = false
    @State private var selectedLocation: WorkoutLocation = .outdoor

    /// Ties the top bar's pills together so `GlassEffectContainer` can morph one into
    /// the next as they appear and disappear, rather than cross-fading them.
    @Namespace private var topBarGlass

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tracker: WorkoutTrackerService { container.workoutTrackerService }

    /// The run session, which outlives this screen so it can be minimised into the
    /// tab-bar accessory (U7). Both of the things a run remembers that the tracker does
    /// not — the scheduled workout it fulfils and the guided stepper's position — live
    /// there rather than in `@State`, because dismissing the cover destroys this view.
    private var presentation: ActiveRunPresentation { container.activeRunPresentation }

    /// The scheduled workout this run fulfills, when launched from "Start This
    /// Workout". `nil` for a free run. Drives the start type and links the saved
    /// run back to the plan so the day is marked complete (H4).
    private var scheduledWorkout: ScheduledWorkout? { presentation.scheduledWorkout }

    /// Guided structured-workout state, present only when this run fulfils a
    /// scheduled workout that carries a multi-segment `WorkoutStructure` (A4).
    /// Flat easy runs and free runs leave this `nil` and are unchanged.
    private var guided: GuidedWorkoutState? { presentation.guided }

    /// The stepper as a binding, for `GuidedWorkoutBanner` to advance. Built here
    /// because `presentation` is a computed property, so `@Bindable` does not apply.
    private var guidedBinding: Binding<GuidedWorkoutState?> {
        Binding(
            get: { presentation.guided },
            set: { presentation.guided = $0 }
        )
    }

    /// Start type for the run: the scheduled workout's type when it's a run
    /// (easy/tempo/interval/long/race), otherwise a free easy run (H4).
    private var startType: WorkoutType {
        if let scheduledType = scheduledWorkout?.workoutType, scheduledType.isRunType {
            return scheduledType
        }
        return .easy
    }

    private var trainingPaces: TrainingPaces? {
        guard let time = profiles.first?.currentEstimated5KTimeSeconds else { return nil }
        return PaceCalculatorService.trainingPaces(from5KTimeSeconds: time)
    }

    private var currentZone: PaceZone {
        guard let paces = trainingPaces, tracker.currentPaceSecondsPerKm > 0 else { return .easy }
        return PaceZone.zone(for: tracker.currentPaceSecondsPerKm, using: paces)
    }

    private var zoneColor: Color { currentZone.color }

    // `body` used to hold the HUD stack and every lifecycle, alert and haptic
    // modifier in one expression, which the type checker could no longer solve in
    // reasonable time. It is split across three properties so each one is a small
    // inference problem: the layered HUD, the lifecycle/alert modifiers, and the
    // haptics. Keep new modifiers in the group they belong to rather than growing
    // one chain back to where it was.
    var body: some View {
        runScreen
            // Haptics: this is a heads-down screen, so state changes have to be felt
            // rather than seen (U4). Declarative `sensoryFeedback` respects the system
            // haptics setting; no UIKit generators.
            //
            // The closure signatures are spelled out: an inferred multi-statement
            // closure returning an implicitly-wrapped `SensoryFeedback?` is what
            // pushed this expression over the type checker's budget.
            .sensoryFeedback(trigger: tracker.trackingState) { (oldState: TrackingState, newState: TrackingState) -> SensoryFeedback? in
                switch newState {
                case .active:   return oldState == .paused ? .selection : .impact(weight: .heavy)
                case .paused:   return .selection
                case .finished: return .success
                case .idle:     return nil
                }
            }
            .sensoryFeedback(.error, trigger: saveErrorMessage != nil) { _, isShowing in isShowing }
            // Each closed kilometre/mile, felt and (opt-in) spoken. Shared with
            // `MainTabView`, which owns the same feedback while the run is minimised and
            // this screen is gone — see `RunSplitFeedback`.
            .runSplitFeedback(isActive: true)
            // A guided interval changing step is otherwise invisible unless the runner
            // happens to be looking at the banner at that moment.
            .sensoryFeedback(trigger: presentation.guided?.stepNumber) { (oldStep: Int?, newStep: Int?) -> SensoryFeedback? in
                guard let oldStep, let newStep, newStep != oldStep else { return nil }
                return .impact(weight: .heavy)
            }
    }

    /// The HUD with everything that runs its lifecycle: appearance setup, the two
    /// outcome dialogs, and the idle-timer hold.
    private var runScreen: some View {
        hudLayers
            .onAppear { prepareForAppearance() }
            // "Finish" used to be the only outcome, so a mis-tapped start that ran for
            // twelve seconds was saved, exported to HealthKit, and marked its scheduled
            // day complete. Strength sessions have had a discard option since H5; runs
            // get one here (N17).
            .confirmationDialog("Finish workout?", isPresented: $showFinishConfirmation, titleVisibility: .visible) {
                Button("Finish & Save") { finishAndSave() }
                Button("Discard Run", role: .destructive) { discardRunWithoutSaving() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Discarding throws this run away — it won't be saved to Stride or Health.")
            }
            // A failed save used to lose the run silently: the tracker has already moved
            // to `.finished` by this point, so there is nothing left to recover from (N15).
            // Stay on the screen so "Try Again" can re-attempt the save with the workout
            // still in hand.
            .alert(
                "Couldn't save your run",
                isPresented: Binding(
                    get: { saveErrorMessage != nil },
                    set: { if !$0 { saveErrorMessage = nil } }
                )
            ) {
                Button("Try Again") { retrySave() }
                Button("Discard", role: .destructive) { discardUnsavedRun() }
            } message: {
                Text(saveErrorMessage ?? "")
            }
            // The display sleeps after 30 seconds on default settings, so the hero pace,
            // zone colour, pace meter and guided-workout banner all went black while the
            // runner was still running — everything this screen exists for stopped
            // working almost immediately (U5a). Held only while tracking, and released
            // on finish/discard so a forgotten flag can't drain the battery afterwards.
            .onChange(of: tracker.trackingState, initial: true) { _, state in
                UIApplication.shared.isIdleTimerDisabled = (state == .active || state == .paused)
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                // Finishing or discarding mid-sentence must not leave the runner's music
                // ducked, so the audio session is released with the screen.
                container.runVoiceCoach.stop()
                // Minimising and ending both take this screen away; only one of them keeps
                // the run (U7). A tracker that is no longer recording means the run is
                // over, so the session behind it — the scheduled workout it fulfilled and
                // the guided stepper — goes now that the cover has actually gone.
                if !presentation.isPresented, !tracker.isRecording {
                    presentation.end()
                }
            }
    }

    private var hudLayers: some View {
        ZStack {
            // Full-bleed zone-color radial gradient backdrop
            // (emanates from the top — matches design spec 130% × 70% at 50% 0%)
            //
            // The top stop used to be the raw zone colour at full luminance, which
            // put every label on this screen between 1.5:1 and 2.3:1 — unreadable
            // outdoors, which is the only place this screen is used (U3b). Each stop
            // is darkened enough that white clears 4.5:1 on the lightest zone
            // (ZoneTempo/ZoneEasy) while the zone stays unmistakably itself.
            // Fractions are tuned for the perceptual blend `mix` uses by default.
            //
            // `GeometryReader` stays here deliberately (U7). `EllipticalGradient` would
            // retire it — as it did on the onboarding glow — but its radii are fractions of
            // both axes, so the three stops would land somewhere else, and *where* they land
            // is what the contrast audit measured (U3b). A geometry-free version of this
            // gradient is a re-tune, not a refactor.
            GeometryReader { geo in
                RadialGradient(
                    stops: [
                        .init(color: zoneColor.mix(with: .black, by: 0.40), location: 0),
                        .init(color: zoneColor.mix(with: .black, by: 0.56), location: 0.55),
                        .init(color: zoneColor.mix(with: .black, by: 0.72), location: 1.0),
                    ],
                    center: .init(x: 0.5, y: 0),
                    startRadius: 0,
                    endRadius: max(geo.size.width * 1.3, geo.size.height * 0.9)
                )
            }
            .ignoresSafeArea()
            .adaptiveAnimation(AppAnimation.gentle, value: currentZone.rawValue)

            // Soft texture overlay — subtle highlight + lowlight for depth
            RadialGradient(
                colors: [Color.white.opacity(0.10), Color.clear],
                center: .init(x: 0.20, y: 0.10),
                startRadius: 0,
                endRadius: 260
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [Color.black.opacity(0.18), Color.clear],
                center: .init(x: 0.80, y: 0.95),
                startRadius: 0,
                endRadius: 320
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                zoneLabel
                heroPace
                if let paces = trainingPaces, tracker.trackingState == .active {
                    paceMeter(paces: paces)
                        .padding(.horizontal, 22)
                        .padding(.top, 22)
                }
                if let unwrappedGuided = Binding(guidedBinding) {
                    GuidedWorkoutBanner(
                        tracker: tracker,
                        guided: unwrappedGuided,
                        unit: appSettings.unitPreference
                    )
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, 18)
                }
                metricsGrid
                Spacer()
                controls
            }
        }
    }

    /// Runs on every appearance, which since U7 includes *reopening* a minimised run —
    /// so everything here has to be safe to repeat mid-run. It is: `prepareForNewWorkout`
    /// only acts on a finished tracker, `setLocation` only on an idle one, and the
    /// guided stepper is built once by `ActiveRunPresentation.start` rather than here,
    /// which used to be the only place it was built and would have put a runner three
    /// intervals in back on step 1.
    private func prepareForAppearance() {
        // Recover from a previous run's terminal state so the start button works.
        tracker.prepareForNewWorkout()
        if tracker.trackingState == .idle {
            // Default the indoor/outdoor toggle to the scheduled workout's location.
            if let scheduledLocation = scheduledWorkout?.workoutLocation {
                selectedLocation = scheduledLocation
                tracker.setLocation(scheduledLocation)
            }
        } else {
            // Reopened mid-run: the toggle is read-only from here on, and it has to show
            // what the run is actually recording rather than this view's fresh default.
            selectedLocation = tracker.workoutLocation
        }
        metricsAppeared = true
        controlsAppeared = true
        if !reduceMotion {
            recPulse = true
            heartPulse = true
        }
    }

    // MARK: - Top bar

    /// The top bar's pills are the one place in the app where several glass surfaces sit
    /// side by side, so it is the one place `GlassEffectContainer` earns its keep — the
    /// earlier pass left it out for exactly that reason, when the bar held at most two.
    ///
    /// Three of the four come and go mid-run (minimize and REC on start, the GPS pill on
    /// the first fix), and inside a container with `glassEffectID`s they melt in and out
    /// of the neighbouring glass instead of popping. `spacing` matches the `HStack`'s,
    /// which is what tells the container how close is close enough to blend.
    private var topBar: some View {
        GlassEffectContainer(spacing: 8) {
            topBarContent
        }
        .padding(.horizontal, 22)
        .padding(.top, AppSpacing.md)
        .foregroundStyle(.white)
        .adaptiveAnimation(AppAnimation.gentle, value: tracker.trackingState)
    }

    private var topBarContent: some View {
        HStack(spacing: 8) {
            minimizeButton
                .glassEffectID("minimize", in: topBarGlass)

            // Indoor / outdoor toggle — only interactive before the workout starts
            locationToggle
                .glassEffectID("location", in: topBarGlass)

            Spacer(minLength: 8)

            // Reception. `nil` indoors and until the first fix arrives.
            if let signal = tracker.gpsSignal {
                gpsSignalPill(signal)
                    .glassEffectID("gps", in: topBarGlass)
            }

            // The idle state used to show a "Lock" pill here. It was decorative — it
            // read as a control to assistive tech and to anyone who tapped it, and
            // locked nothing (N18). Removed rather than faked.
            if tracker.trackingState == .active || tracker.trackingState == .paused {
                glassPill {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 4))
                        .scaleEffect(recPulse ? 1.35 : 1.0)
                        .opacity(recPulse ? 0.45 : 1.0)
                        .animation(
                            reduceMotion ? .default : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                            value: recPulse
                        )
                    Text("REC")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .kerning(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tracker.trackingState == .paused ? "Run paused" : "Recording run")
                .glassEffectID("rec", in: topBarGlass)
            }
        }
    }

    /// The way off this screen that isn't ending the run (U7).
    ///
    /// Before this there was none: the HUD was a `fullScreenCover` with no close control,
    /// so a runner who wanted to look at next week's plan, or who opened the screen by
    /// mistake and hadn't started yet, had to Finish or Discard to get out. Mid-run it
    /// minimises into the tab-bar accessory, which keeps recording and offers the way
    /// back; before the run starts there is no session to minimise, so it closes.
    private var minimizeButton: some View {
        let isIdle = tracker.trackingState == .idle
        return Button {
            if isIdle {
                endRun()
            } else {
                presentation.minimize()
            }
        } label: {
            glassControlButton(size: 44) {
                StrideIcon(
                    name: isIdle ? .close : .chevronDown,
                    size: 16,
                    color: .white,
                    strokeWeight: 2.4
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isIdle ? "Close" : "Minimize run")
        .accessibilityHint(
            isIdle
                ? "Leaves without starting a run"
                : "Keeps recording and shows the run above the tab bar"
        )
        .accessibilityIdentifier("activeRun.minimize")
    }

    /// GPS reception, surfaced on the screen the runner is actually looking at (U5c).
    ///
    /// `LocationQualityFilter` has always graded every fix and `WorkoutTrackerService`
    /// has always counted the discards, but both stayed in the log: under tree cover
    /// the HUD showed a confident pace derived from fixes that were being thrown away.
    ///
    /// Quality is carried by the number of filled bars, not by colour alone, so it
    /// survives Differentiate Without Color and a monochrome glance mid-stride. The
    /// weak state adds a word, because that is the one a runner should act on.
    private func gpsSignalPill(_ signal: LocationQualityFilter.SignalQuality) -> some View {
        glassPill {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(1...3, id: \.self) { bar in
                    Capsule()
                        .fill(.white.opacity(bar <= signal.bars ? 1 : 0.3))
                        .frame(width: 3, height: 4 + CGFloat(bar) * 3)
                }
            }
            .frame(height: 13, alignment: .bottom)

            if signal == .weak {
                Text("Weak GPS")
                    .font(.system(size: 12, weight: .bold))
                    .kerning(0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GPS signal")
        .accessibilityValue(signal.localizedName)
        .accessibilityIdentifier("activeRun.gpsSignal")
        .adaptiveAnimation(AppAnimation.gentle, value: signal.rawValue)
    }

    private var locationToggle: some View {
        let isIdle = tracker.trackingState == .idle
        return Button {
            guard isIdle else { return }
            selectedLocation = selectedLocation == .outdoor ? .indoor : .outdoor
            tracker.setLocation(selectedLocation)
        } label: {
            glassPill {
                Image(systemName: selectedLocation.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(selectedLocation.localizedName)
                    .font(.system(size: 12, weight: .bold))
                    .kerning(0.5)
            }
            .opacity(isIdle ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!isIdle)
        .accessibilityLabel("Workout location")
        .accessibilityValue(selectedLocation.localizedName)
        .accessibilityHint("Switches between outdoor GPS and indoor tracking. Only before the run starts.")
        .adaptiveAnimation(AppAnimation.gentle, value: selectedLocation.rawValue)
    }

    // MARK: - Zone label pill

    private var zoneLabel: some View {
        HStack(spacing: 8) {
            StrideIcon(name: currentZone.strideIcon, size: 14, color: .white, strokeWeight: 2.4)
            Text("\(currentZone.rawValue.uppercased()) ZONE")
                .font(.system(size: 12, weight: .bold))
                .kerning(1.4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .padding(.top, 28)
        .adaptiveAnimation(AppAnimation.bouncy, value: currentZone.rawValue)
    }

    // MARK: - Hero pace display

    private var heroPace: some View {
        VStack(spacing: 6) {
            // `paceValueString`, not `paceString`: the latter carries "min/mi" inside the
            // string, which the caption below already says. At 120pt that duplicate unit
            // cannot fit, so `lineLimit(1)` truncated the hero to "--:-- min…" and ran it
            // off the right edge of the screen (S1).
            Text(tracker.currentPaceSecondsPerKm.paceValueString(unit: appSettings.unitPreference))
                .font(.metricHero)
                .kerning(-4.8)                       // -0.04em at 120pt
                .lineSpacing(-12)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(.white)
                // This screen keeps its inline shadows, and is excluded from
                // `no_inline_shadow` for it (U1). Everywhere else a shadow means
                // height and belongs to `AppElevation`; here the four shadows are
                // legibility aids tuned against a saturated full-bleed gradient —
                // separating white type and white controls from a background that
                // changes colour with the pace zone. A neutral page-elevation token
                // would be both too weak and the wrong intent.
                .shadow(color: .black.opacity(0.15), radius: 15, y: 4)
                .contentTransition(.numericText())
                .animation(.linear(duration: 0.2), value: tracker.currentPaceSecondsPerKm)

            Text("CURRENT PACE · \(paceUnitLabel.uppercased())")
                .font(.system(size: 12, weight: .bold))
                .kerning(2.2)
                .foregroundStyle(.white.opacity(0.95))
        }
        .padding(.top, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current pace")
        .accessibilityValue(tracker.currentPaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
    }

    private var paceUnitLabel: String {
        appSettings.unitPreference.paceLabel    // "min/km" or "min/mi"
    }

    // MARK: - Pace meter

    private func paceMeter(paces: TrainingPaces) -> some View {
        let current = tracker.currentPaceSecondsPerKm
        let low = paces.easyRange.lowerBound
        let high = paces.easyRange.upperBound
        let rangeMin = low - 60.0
        let rangeMax = high + 60.0
        let pct = rangeMax > rangeMin
            ? CGFloat((current - rangeMin) / (rangeMax - rangeMin)).clamped(to: 0...1)
            : 0.5
        let lowPct = CGFloat((low - rangeMin) / (rangeMax - rangeMin)).clamped(to: 0...1)
        let highPct = CGFloat((high - rangeMin) / (rangeMax - rangeMin)).clamped(to: 0...1)

        return VStack(spacing: 8) {
            HStack {
                Text("slower")
                Spacer()
                Text("target")
                Spacer()
                Text("faster")
            }
            .font(.system(size: 11, weight: .bold))
            .kerning(1.2)
            .foregroundStyle(.white.opacity(0.92))

            // `GeometryReader` stays here deliberately (U7). The marker's offset alone could
            // move to `visualEffect`, but the target band needs a measured *width* as well,
            // so converting half of it would leave the reader in place and split one piece of
            // geometry across two idioms.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(.black.opacity(0.25))
                        .frame(height: 10)

                    // Target band
                    let bandX = geo.size.width * lowPct
                    let bandW = geo.size.width * (highPct - lowPct)
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .shadow(color: .white.opacity(0.35), radius: 6)
                        .frame(width: max(bandW, 8), height: 10)
                        .offset(x: bandX)

                    // Marker
                    Circle()
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 3))
                        .offset(x: geo.size.width * pct - 10)
                        .animation(.linear(duration: 0.2), value: pct)
                }
                .frame(height: 10)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pace against your target range")
        .accessibilityValue("\(currentZone.rawValue) zone")
    }

    // MARK: - Metrics grid

    private var metricsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
            metricCell(
                value: tracker.distanceMeters.distanceString(unit: appSettings.unitPreference),
                label: "Distance"
            )
            metricCell(
                value: tracker.elapsedSeconds.durationString,
                label: "Time"
            )
            if let hr = tracker.currentHeartRate {
                heartRateCell(bpm: Int(hr))
            } else {
                metricCell(value: "--", label: "Heart Rate")
            }
            // Cadence and elevation were hardcoded `--` while the app already had
            // both numbers: elevation was accumulated but unpublished, and the
            // pedometer reports cadence on every run (N20).
            metricCell(value: cadenceValue, unit: "spm", label: "Cadence")
            metricCell(value: elevationValue, unit: elevationUnitLabel, label: "Elev Gain")
            if let guided {
                // Repurpose the previously dead hardcoded "Lap" cell to show
                // progress through the guided workout's steps (A4).
                metricCell(value: "\(guided.stepNumber)/\(guided.stepCount)", label: "Step")
            } else {
                // The "Lap" cell was dead too — there is no lap marker in the app, and
                // the flag button that would have set one did nothing (N18/N20). Show
                // average pace instead, which complements the live hero pace.
                metricCell(
                    value: averagePaceSecondsPerKm.paceValueString(unit: appSettings.unitPreference),
                    unit: appSettings.unitPreference == .metric ? "/km" : "/mi",
                    label: "Avg Pace"
                )
            }
        }
        .padding(AppSpacing.xl)
        .glassEffect(.regular, in: .rect(cornerRadius: AppRadius.xl))
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, 26)
        // Three fixed-width columns above a hero that already fills the screen: this
        // grid is one of the two places in the app that genuinely cannot reflow, so
        // it is clamped rather than left to overflow (U2). Its fonts are the fixed
        // `metric*` tokens; the clamp covers anything nested that isn't.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .opacity(metricsAppeared ? 1 : 0)
        .scaleEffect(metricsAppeared ? 1 : 0.92)
        .adaptiveAnimation(AppAnimation.entrance.delay(0.1), value: metricsAppeared)
    }

    /// Live cadence for the metric grid, `--` until the pedometer reports a sample.
    private var cadenceValue: String {
        guard let cadence = tracker.currentCadenceStepsPerMinute, cadence > 0 else { return "--" }
        return "\(Int(cadence.rounded()))"
    }

    /// Elevation gained so far, in the runner's own unit.
    private var elevationValue: String {
        let gain = tracker.elevationGainMeters.elevationValue(unit: appSettings.unitPreference)
        return String(format: "%.0f", gain)
    }

    private var elevationUnitLabel: String {
        appSettings.unitPreference == .metric ? "m" : "ft"
    }

    /// Session-average pace in seconds per km, or 0 before any distance is recorded
    /// (`paceValueString` renders that as `--:--`).
    private var averagePaceSecondsPerKm: Double {
        guard tracker.distanceMeters > 0, tracker.elapsedSeconds > 0 else { return 0 }
        return tracker.elapsedSeconds / tracker.distanceMeters * 1_000
    }

    private func heartRateCell(bpm: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text("\(bpm)")
                    .font(.metricSmall)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .scaleEffect(heartPulse ? 1.06 : 1.0, anchor: .bottomLeading)
                    .animation(
                        reduceMotion ? .default : .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                        value: heartPulse
                    )
                Text("bpm")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
            }
            Text("HEART RATE")
                .font(.metricLabel)
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.92))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate")
        .accessibilityValue("\(bpm) beats per minute")
        .accessibilityIdentifier(Self.metricIdentifier("Heart Rate"))
    }

    private func metricCell(value: String, unit: String? = nil, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.metricSmall)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            Text(label.uppercased())
                .font(.metricLabel)
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.92))
        }
        // Without this a six-cell grid reads to VoiceOver as twelve loose fragments
        // ("5.2", "DISTANCE", "27:14", "TIME", …) with no pairing (N18).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(SpokenMetric.spoken(value: value, unit: unit))
        .accessibilityIdentifier(Self.metricIdentifier(label))
    }

    /// Stable identifier for a metric cell, e.g. `activeRun.metric.Distance`. Merging
    /// each cell into one accessibility element hides the inner `Text`s, so
    /// `StrideUITests` matches on these identifiers rather than on the uppercased label.
    private static func metricIdentifier(_ label: String) -> String {
        "activeRun.metric." + label.replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Controls

    private var controls: some View {
        // The flag/lap button that used to sit on the left is gone: it had no action,
        // and the "Lap" cell it would have driven was hardcoded to `--` (N18/N20).
        HStack(spacing: 22) {
            // Primary pause/play
            Group {
                if tracker.trackingState == .active {
                    filledControlButton(size: 84, tintColor: zoneColor) {
                        tracker.pauseWorkout()
                    } label: {
                        StrideIcon(name: .pause, size: 28, color: zoneColor, strokeWeight: 2.2)
                    }
                    .accessibilityLabel("Pause run")
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                } else if tracker.trackingState == .paused {
                    filledControlButton(size: 84, tintColor: zoneColor) {
                        tracker.resumeWorkout()
                    } label: {
                        StrideIcon(name: .play, size: 28, color: zoneColor, strokeWeight: 2.2)
                    }
                    .accessibilityLabel("Resume run")
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                } else {
                    filledControlButton(size: 84, tintColor: zoneColor) {
                        tracker.setLocation(selectedLocation)
                        tracker.startWorkout(type: startType, distanceUnit: appSettings.unitPreference)
                    } label: {
                        StrideIcon(name: .play, size: 28, color: zoneColor, strokeWeight: 2.2)
                    }
                    .accessibilityLabel("Start run")
                    .accessibilityIdentifier("activeRun.start")
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .adaptiveAnimation(AppAnimation.bouncy, value: tracker.trackingState == .active)

            // A `.onTapGesture` on a decorative `ZStack` meant VoiceOver users could
            // not end a run at all — the app's most important control was invisible
            // to assistive tech. It is a `Button` now (N18).
            Button {
                showFinishConfirmation = true
            } label: {
                glassControlButton(size: 64) {
                    StrideIcon(name: .stop, size: 22, color: .white, strokeWeight: 2.2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Finish run")
            .accessibilityHint("Choose to save or discard this run")
            .accessibilityIdentifier("activeRun.finish")
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, AppSpacing.huge)
        .opacity(controlsAppeared ? 1 : 0)
        .offset(y: controlsAppeared ? 0 : 30)
        .adaptiveAnimation(AppAnimation.entrance.delay(0.2), value: controlsAppeared)
    }

    // MARK: - Control button helpers

    /// Liquid Glass, not a simulation of it.
    ///
    /// This used to be `.ultraThinMaterial` under a hand-drawn `strokeBorder`, which
    /// looks close but is inert: it does not respond to Reduce Transparency or to
    /// Increase Contrast, and it does not pick up the specular edge that makes the
    /// real material read as a control. `.glassEffect` handles all three, and
    /// `.interactive()` adds the press reaction the hand-rolled version never had (U7).
    @ViewBuilder
    private func glassControlButton<Label: View>(size: CGFloat, @ViewBuilder label: () -> Label) -> some View {
        ZStack { label() }
            .frame(width: size, height: size)
            .glassEffect(.regular.interactive(), in: .circle)
    }

    @ViewBuilder
    private func filledControlButton<Label: View>(
        size: CGFloat,
        tintColor: Color,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 0.5))
                    .frame(width: size, height: size)
                label()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Glass pill helper

    @ViewBuilder
    private func glassPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, AppSpacing.sm)
            .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Actions

    /// Takes the HUD off screen at the end of a run — saved, discarded, or closed before
    /// it ever started.
    ///
    /// This is the counterpart to `presentation.minimize()`, and the distinction is the
    /// whole point of U7: minimising leaves the session standing so the accessory can show
    /// it, while every path through here is finished with the run. The session itself is
    /// torn down by `onDisappear` rather than here, once the cover has actually gone;
    /// `onDisappear` can tell the two exits apart, because a minimised run is still
    /// recording and an ended one is not.
    ///
    /// Dismissing through the presentation rather than `@Environment(\.dismiss)` is what
    /// keeps the accessory and the HUD from disagreeing about where the run is.
    private func endRun() {
        presentation.isPresented = false
    }

    private func finishAndSave() {
        // `finishWorkout()` is one-shot — it transitions the tracker to `.finished`
        // and a second call returns nil — so the run is held in `pendingSave` and a
        // failed save is retried from there rather than re-finishing the tracker.
        guard let workout = pendingSave ?? tracker.finishWorkout() else { endRun(); return }
        pendingSave = workout
        persistFinishedRun(workout)
    }

    /// Ends tracking and throws the run away without persisting it (N17).
    ///
    /// Nothing has been inserted into the context at this point — the insert and the
    /// scheduled-day link both happen in `persistFinishedRun` — so stopping the
    /// tracker and dismissing is the whole job.
    private func discardRunWithoutSaving() {
        _ = tracker.finishWorkout()
        pendingSave = nil
        AppLogger.log("Run discarded from the finish dialog; nothing saved", label: "ActiveRun")
        endRun()
    }

    private func retrySave() {
        saveErrorMessage = nil
        guard let workout = pendingSave else { endRun(); return }
        persistFinishedRun(workout)
    }

    private func discardUnsavedRun() {
        saveErrorMessage = nil
        // Undo the link too, or the scheduled day is left marked complete with no
        // run behind it (the relationship nullifies when the run is deleted).
        if let scheduled = scheduledWorkout {
            scheduled.completedWorkout = nil
            scheduled.linkedRunWorkoutID = nil
            scheduled.isCompleted = false
        }
        if let workout = pendingSave {
            context.delete(workout)
            pendingSave = nil
        }
        context.saveOrLog("the discard of an unsaved run")
        endRun()
    }

    private func persistFinishedRun(_ workout: RunWorkout) {
        context.insert(workout)
        // Link the run back to its scheduled day so the plan marks it complete
        // and the calendar/recovery card don't nag about a workout that was done (H4).
        //
        // A run that doesn't clear the shared effort floor is still saved — the runner
        // can see and delete it — but it must not complete a planned session, the same
        // way the importer refuses to import a tiny HealthKit shell (N17).
        if let scheduled = scheduledWorkout {
            if RunEffortPolicy.canCompleteScheduledWorkout(workout) {
                workout.scheduledWorkout = scheduled
                workout.linkedScheduledWorkoutID = scheduled.id
                scheduled.completedWorkout = workout
                scheduled.linkedRunWorkoutID = workout.id
                scheduled.isCompleted = true
            } else {
                AppLogger.log(
                    "Run \(workout.id) is below the effort floor "
                        + "(\(Int(workout.distanceMeters)) m / \(Int(workout.durationSeconds)) s); "
                        + "saved without completing the scheduled workout",
                    label: "ActiveRun"
                )
            }
        }

        // The run only exists in memory until this succeeds. Surface a failure and
        // stay on the screen instead of dismissing over a lost workout (N15).
        do {
            try context.save()
        } catch {
            AppLogger.log(
                "Failed to save finished run \(workout.id): \(error.localizedDescription)",
                label: "ActiveRun",
                level: .error
            )
            saveErrorMessage = """
            Your run couldn't be saved to this device. It's still here — try again, \
            or discard it.

            \(error.localizedDescription)
            """
            return
        }
        pendingSave = nil

        Task { @MainActor in
            if let hkID = try? await container.healthKitRepository.save(workout) {
                workout.healthKitWorkoutID = hkID
                context.saveOrLog("the run's HealthKit id")
            }
        }
        if let coordinate = tracker.coordinates.first {
            Task {
                await container.attachWeather(to: workout, coordinate: coordinate)
            }
        }
        if let profile = profiles.first, let plan = activePlans.first {
            let allHistory = (try? context.fetch(FetchDescriptor<RunWorkout>())) ?? []
            container.planLifecycle.refreshPlanAfterWorkout(
                plan: plan,
                history: allHistory,
                profile: profile,
                unitPreference: appSettings.unitPreference
            )
            context.saveOrLog("training paces refreshed after the run")
        }
        // Finishing a run is the moment every widget's content changes at once — the
        // week's total, the streak, and the plan's next session all move — and it is the
        // one moment the runner is most likely to go straight to the Home Screen to look
        // at (B1). The scene-phase refresh would catch it eventually; this catches it now.
        WidgetRefreshService.refresh(context: context, appSettings: appSettings)
        endRun()
    }
}

// MARK: - Comparable+clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        max(range.lowerBound, min(self, range.upperBound))
    }
}

// The hand-rolled `Color.mix(with:by:)` that used to live here blended through
// `UIColor` in sRGB and dropped alpha. `Color.mix(with:by:in:)` has been native
// since iOS 18 — well below this app's 27.0 floor — and blends perceptually (U7).
