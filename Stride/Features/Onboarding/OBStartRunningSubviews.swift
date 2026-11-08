import SwiftUI

// MARK: - Onboarding: Start Running
//
// The Start Running plan's onboarding surface: its card on the goal step, the starting-point
// question that takes the 5K-time step's place (a runner who can't yet run five minutes has
// no 5K time to give), and its own summary screen. Every number comes from
// `StartRunningProgram`; why each is what it is, see `docs/START_RUNNING_PROGRAM.md`.

// MARK: - OBStartRunningPlanCard

/// The Start Running option on the goal step, under the "Specialized" heading with the
/// pregnancy plan: it isn't a race distance, and picking it re-points the rest of onboarding.
struct OBStartRunningPlanCard: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.brand.opacity(0.15)).frame(width: 48, height: 48)
                    StrideIcon(name: .walk, size: 22, color: .brand, strokeWeight: 2.2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Start Running").font(.dsSubhead.weight(.semibold))
                        Text("Run/walk")
                            .font(.dsCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    Text("New or coming back · run/walk up to 30 minutes non-stop")
                        .font(.dsCaption).foregroundStyle(.secondary)
                }
                Spacer()
                OBRadio(isSelected: isSelected, color: .brand)
            }
            .padding(AppSpacing.lg)
            .strideCard(cornerRadius: AppRadius.lg)
            .overlay(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(isSelected ? Color.brand : Color.clear, lineWidth: 2))
        }
        .buttonStyle(BouncyButtonStyle())
        .foregroundStyle(.primary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("onboarding.plan.startRunning")
    }
}

// MARK: - OBStartingPointPicker

/// "How long can you run without stopping?" Each answer shows the first week it leads to,
/// so the runner sees what they are signing up for before they pick.
struct OBStartingPointPicker: View {
    @Binding var selection: StartRunningProgram.StartingPoint

    var body: some View {
        VStack(spacing: 10) {
            ForEach(StartRunningProgram.StartingPoint.allCases) { point in
                row(point)
            }

            Text("Can already run about 20 minutes? A 5K plan will suit you better: go back and pick one.")
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, AppSpacing.xs)
        }
    }

    private func row(_ point: StartRunningProgram.StartingPoint) -> some View {
        let isSelected = selection == point
        let firstWeek = StartRunningProgram.stage(point.firstStage)
        return Button {
            selection = point
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(point.localizedName)
                        .font(.dsHeadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("Week 1: \(firstWeek.summary)")
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                    Text("\(point.weeks) weeks to 30 minutes")
                        .font(.dsCaption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary.opacity(0.75))
                }
                Spacer()
                OBRadio(isSelected: isSelected, color: .brand)
            }
            .padding(14)
            .strideCard(cornerRadius: AppRadius.md)
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(isSelected ? Color.brand : Color.clear, lineWidth: 2))
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("onboarding.startingPoint.\(point.rawValue)")
    }
}

// MARK: - OBStartRunningSwitchHint

/// Shown on the level step when someone picks "New to running" for a race or fitness plan.
/// Those plans start at continuous running; this is the one place that says a run/walk plan
/// exists for someone who can't do that yet.
struct OBStartRunningSwitchHint: View {
    let onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StrideIcon(name: .walk, size: 18, color: .brand, strokeWeight: 2.0)
                Text("Can't run for 20 minutes yet?")
                    .font(.dsSubhead.weight(.semibold))
            }
            Text("Start Running builds up with run/walk first: one minute at a time, to 30 minutes without stopping.")
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Switch to Start Running", action: onSwitch)
                .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
                .accessibilityIdentifier("onboarding.switchToStartRunning")
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.md)
    }
}

// MARK: - OBStartRunningReady

/// The summary screen for a Start Running plan, in place of `OBReady`, which would promise a
/// peak weekly distance and a pace this plan doesn't have.
struct OBStartRunningReady: View {
    let startingPoint: StartRunningProgram.StartingPoint
    let runDaysPerWeek: Int
    var progressTotal = 8
    let isCreatingPlan: Bool
    let onBack: () -> Void
    let onViewPlan: () -> Void

    private var firstWeek: StartRunningProgram.Stage {
        StartRunningProgram.stage(startingPoint.firstStage)
    }

    private let howItWorks: [(icon: StrideIconName, text: LocalizedStringKey)] = [
        (.timer, "Every session is set in minutes, not distance or pace. Run slowly enough to talk in short sentences."),
        (.walk, "Each run starts and ends with a 5 minute walk. The walks in between are part of the plan."),
        (.calendar, "Same session every run day for a week, then a little more running the next."),
        (.flag, "The last week is 30 minutes without stopping. A 5K plan picks up from there.")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            MapBackdrop().ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 54)
                HStack(spacing: 14) {
                    OBBackButton(
                        identifier: "onboarding.back.\(progressTotal)",
                        isDisabled: isCreatingPlan,
                        action: onBack
                    )

                    StrideProgressBar(value: 1, height: 4)
                        .accessibilityHidden(true)
                    Text("\(progressTotal)/\(progressTotal)")
                        .font(.dsCaption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, AppSpacing.xxl)
                .padding(.top, AppSpacing.sm)
                .padding(.bottom, 22)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your plan")
                                .strideEyebrow()
                                .foregroundStyle(.brandText)
                            Text("\(startingPoint.weeks) weeks to\n30 minutes non-stop.")
                                .font(.dsTitle1.weight(.heavy))
                                .kerning(-0.7)
                                .foregroundStyle(.primary)
                                .lineSpacing(-2)
                        }

                        // The plan summary: the screen's one hero.
                        HStack(spacing: 0) {
                            OBStartRunningStat(label: "WEEKS", value: "\(startingPoint.weeks)")
                            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 36)
                            OBStartRunningStat(label: "RUNS A WEEK", value: "\(runDaysPerWeek)")
                            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 36)
                            OBStartRunningStat(label: "LONGEST RUN", value: StartRunningProgram.clock(firstWeek.runSeconds))
                        }
                        .padding(AppSpacing.lg)
                        .heroCard()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("WEEK 1")
                                .strideEyebrow()
                                .foregroundStyle(.secondary)
                            Text(firstWeek.summary)
                                .font(.dsHeadline.weight(.bold))
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppSpacing.lg)
                        .strideCard(cornerRadius: AppRadius.lg)

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(howItWorks.enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .top, spacing: 12) {
                                    StrideIcon(name: row.icon, size: 16, color: .brand, strokeWeight: 2.0)
                                        .padding(.top, 1)
                                    Text(row.text)
                                        .font(.dsFootnote)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(AppSpacing.lg)
                        .strideCard(cornerRadius: AppRadius.lg)

                        Text(
                            """
                            Stop and get checked if you have chest pain, feel faint, or have pain \
                            that gets worse as you run. If you're worried about your health, talk \
                            to a doctor before you start.
                            """
                        )
                        .font(.dsCaption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, AppSpacing.xxl)
                    .padding(.top, AppSpacing.sm)
                    .padding(.bottom, AppSpacing.lg)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { cta }
            }
        }
    }

    private var cta: some View {
        Button(action: onViewPlan) {
            Group {
                if isCreatingPlan {
                    ProgressView().tint(.onFill)
                } else {
                    HStack(spacing: 10) {
                        Text("Start my plan")
                        StrideIcon(name: .chevronRight, size: 15, color: .onFill, strokeWeight: 2.6)
                    }
                }
            }
        }
        .buttonStyle(.strideButton())
        .disabled(isCreatingPlan)
        .accessibilityIdentifier("onboarding.startTraining")
        .padding(.horizontal, AppSpacing.xxl)
        .padding(.top, AppSpacing.sm)
        .padding(.bottom, 44)
    }
}

// MARK: - OBStartRunningStat

private struct OBStartRunningStat: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.dsTitle2.monospacedDigit())
                .kerning(-0.5)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}
