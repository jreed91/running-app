import SwiftUI
import SwiftData

struct ActiveRunView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings

    /// The scheduled workout this run fulfills, when launched from "Start This
    /// Workout". `nil` for a free run. Drives the start type and links the saved
    /// run back to the plan so the day is marked complete (H4).
    var scheduledWorkout: ScheduledWorkout? = nil

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

    /// Guided structured-workout state, present only when this run fulfils a
    /// scheduled workout that carries a multi-segment `WorkoutStructure` (A4).
    /// Flat easy runs and free runs leave this `nil` and are unchanged.
    @State private var guided: GuidedWorkoutState?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tracker: WorkoutTrackerService { container.workoutTrackerService }

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

    var body: some View {
        ZStack {
            // Full-bleed zone-color radial gradient backdrop
            // (emanates from the top — matches design spec 130% × 70% at 50% 0%)
            GeometryReader { geo in
                RadialGradient(
                    stops: [
                        .init(color: zoneColor, location: 0),
                        .init(color: zoneColor.mix(with: .black, by: 0.25), location: 0.55),
                        .init(color: zoneColor.mix(with: .black, by: 0.55), location: 1.0),
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
                if let guidedBinding = Binding($guided) {
                    GuidedWorkoutBanner(
                        tracker: tracker,
                        guided: guidedBinding,
                        unit: appSettings.unitPreference
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                }
                metricsGrid
                Spacer()
                controls
            }
        }
        .onAppear {
            // Recover from a previous run's terminal state so the start button works.
            tracker.prepareForNewWorkout()
            // Build the guided-workout stepper when this run fulfils a structured
            // scheduled workout (A4); a nil/flat structure leaves guided mode off.
            if let structure = scheduledWorkout?.workoutStructure, !structure.mainSets.isEmpty {
                guided = GuidedWorkoutState(structure: structure)
            }
            // Default the indoor/outdoor toggle to the scheduled workout's location.
            if let scheduledLocation = scheduledWorkout?.workoutLocation {
                selectedLocation = scheduledLocation
                tracker.setLocation(scheduledLocation)
            }
            metricsAppeared = true
            controlsAppeared = true
            if !reduceMotion {
                recPulse = true
                heartPulse = true
            }
        }
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
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            // Indoor / outdoor toggle — only interactive before the workout starts
            locationToggle

            Spacer()

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
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 56)
        .foregroundStyle(.white)
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
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        .padding(.top, 28)
        .adaptiveAnimation(AppAnimation.bouncy, value: currentZone.rawValue)
    }

    // MARK: - Hero pace display

    private var heroPace: some View {
        VStack(spacing: 6) {
            Text(tracker.currentPaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                .font(.metricHero)
                .kerning(-4.8)                       // -0.04em at 120pt
                .lineSpacing(-12)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 15, y: 4)
                .contentTransition(.numericText())
                .animation(.linear(duration: 0.2), value: tracker.currentPaceSecondsPerKm)

            Text("CURRENT PACE · \(paceUnitLabel.uppercased())")
                .font(.system(size: 12, weight: .bold))
                .kerning(2.2)
                .foregroundStyle(.white.opacity(0.85))
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
            .font(.system(size: 10, weight: .bold))
            .kerning(1.2)
            .foregroundStyle(.white.opacity(0.65))

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
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.top, 26)
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
                    .foregroundStyle(.white.opacity(0.65))
            }
            Text("HEART RATE")
                .font(.system(size: 9, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.55))
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
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.55))
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
        .padding(.horizontal, 16)
        .padding(.bottom, 40)
        .opacity(controlsAppeared ? 1 : 0)
        .offset(y: controlsAppeared ? 0 : 30)
        .adaptiveAnimation(AppAnimation.entrance.delay(0.2), value: controlsAppeared)
    }

    // MARK: - Control button helpers

    @ViewBuilder
    private func glassControlButton<Label: View>(size: CGFloat, @ViewBuilder label: () -> Label) -> some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                .frame(width: size, height: size)
            label()
        }
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
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
    }

    // MARK: - Actions

    private func finishAndSave() {
        // `finishWorkout()` is one-shot — it transitions the tracker to `.finished`
        // and a second call returns nil — so the run is held in `pendingSave` and a
        // failed save is retried from there rather than re-finishing the tracker.
        guard let workout = pendingSave ?? tracker.finishWorkout() else { dismiss(); return }
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
        dismiss()
    }

    private func retrySave() {
        saveErrorMessage = nil
        guard let workout = pendingSave else { dismiss(); return }
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
        dismiss()
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
        dismiss()
    }
}

// MARK: - Comparable+clamped

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        max(range.lowerBound, min(self, range.upperBound))
    }
}

// MARK: - Color+mix

private extension Color {
    func mix(with other: Color, by amount: Double) -> Color {
        let a = amount.clamped(to: 0...1)
        // Blend via UIColor for correctness
        let ui1 = UIColor(self)
        let ui2 = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        ui1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        ui2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            red: r1 + (r2 - r1) * a,
            green: g1 + (g2 - g1) * a,
            blue: b1 + (b2 - b1) * a
        )
    }
}
