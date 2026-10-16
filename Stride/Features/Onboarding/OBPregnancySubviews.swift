import SwiftUI

// MARK: - Onboarding: specialized plans
//
// The pregnancy plan's onboarding surface. Kept out of `OnboardingSubviews.swift` because
// it is a self-contained branch of the flow — the goal step's specialized section, the two
// steps that replace race timing and 5K calibration, and its own summary screen.
//
// Every number and every warning below comes from `PregnancyRunningPolicy`, which carries
// its sources; see `docs/PREGNANCY_RUNNING_EVIDENCE.md`.

// MARK: - OBSpecializedPlanCard

/// The pregnancy option on the goal step.
///
/// Deliberately below a "Specialized" heading rather than as a sixth `OBRaceCard`: it is not
/// a race distance, it selects a different generator, and the five cards above it are all
/// answers to "how far". Putting it in the same list would make "Pregnancy" read as a goal
/// distance and would hide that choosing it changes the rest of onboarding.
struct OBSpecializedPlanCard: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.brand.opacity(0.15)).frame(width: 48, height: 48)
                    StrideIcon(name: .heart, size: 22, color: .brand, strokeWeight: 2.2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Pregnancy").font(.bodyStrong)
                        Text("No race target")
                            .font(.dsCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    Text("Built from ACOG and Canadian guidelines · runs to your due date")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                OBRadio(isSelected: isSelected, color: .brand)
            }
            .padding(AppSpacing.lg)
            .strideCard(cornerRadius: AppRadius.lg)
            .overlay(RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(isSelected ? Color.brand : Color.clear, lineWidth: 2))
        }
        .buttonStyle(BouncyButtonStyle())
        .foregroundStyle(.primary)
        .accessibilityIdentifier("onboarding.plan.pregnancy")
    }
}

// MARK: - OBDueDateCard

struct OBDueDateCard: View {
    @Binding var dueDate: Date
    /// Gestational age on the plan's first day, so the runner can sanity-check the date
    /// against what their own notes say before anything is generated.
    let gestationalAgeAtStart: GestationalAge
    let minimumDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StrideIcon(name: .calendar, size: 18, color: .brand)
                Text("DUE DATE")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
            }

            DatePicker(
                "Estimated due date",
                selection: $dueDate,
                in: minimumDate...minimumDate.adding(days: 300),
                displayedComponents: .date
            )
            .font(.bodyStrong)

            HStack(spacing: 8) {
                Text(gestationalAgeAtStart.noteForm)
                    .font(.dsSubhead.weight(.bold).monospacedDigit())
                    .foregroundStyle(.brandText)
                Text("weeks at plan start · \(gestationalAgeAtStart.trimester.localizedName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }
}

// MARK: - OBPregnancyHealthCheckCard

/// The contraindication gate, on the step that decides whether a plan gets built at all.
///
/// The lists are collapsed by default but reproduced in full when opened, and the confirm
/// row is the only thing that enables the step's Continue button. An abridged version of
/// either list would read as complete, which is the failure this screen exists to avoid.
struct OBPregnancyHealthCheckCard: View {
    @Binding var isConfirmed: Bool

    @State private var showAbsolute = false
    @State private var showRelative = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StrideIcon(name: .heart, size: 18, color: .brand)
                Text("HEALTH CHECK")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
            }

            Text("Some conditions mean no more activity than usual daily living. Others mean the decision is your provider's, not this app's.")
                .font(.caption)
                .foregroundStyle(.secondary)

            disclosure(
                title: "Don't start without talking to your provider",
                isExpanded: $showAbsolute,
                items: PregnancyContraindication.absolute
            )
            disclosure(
                title: "Your provider's call, not ours",
                isExpanded: $showRelative,
                items: PregnancyContraindication.relative
            )

            Divider()

            Button {
                withAnimation(AppAnimation.snappy) { isConfirmed.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.xs)
                            .fill(isConfirmed ? Color.brand : Color.surfaceTertiary)
                            .frame(width: 26, height: 26)
                        if isConfirmed {
                            StrideIcon(name: .check, size: 14, color: .onFill, strokeWeight: 2.6)
                        }
                    }
                    Text("None of those apply to me, and I've talked to my maternity provider about running.")
                        .font(.dsFootnote)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("onboarding.pregnancy.confirm")

            Text(PregnancyRunningPolicy.medicalDisclaimer)
                .font(.dsCaption2)
                .foregroundStyle(.secondary)
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }

    private func disclosure(
        title: String,
        isExpanded: Binding<Bool>,
        items: [PregnancyContraindication]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(AppAnimation.snappy) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.dsFootnote.weight(.semibold))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    StrideIcon(
                        name: isExpanded.wrappedValue ? .chevronDown : .chevronRight,
                        size: 12,
                        color: .secondary,
                        strokeWeight: 2.4
                    )
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").font(.dsCaption).foregroundStyle(.secondary)
                            Text(item.localizedText)
                                .font(.dsCaption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(AppSpacing.sm)
        .background(Color.surfaceTertiary.opacity(0.6), in: RoundedRectangle(cornerRadius: AppRadius.sm))
    }
}

// MARK: - OBPrePregnancyRunningCard

/// The two inputs the taper is built from.
///
/// Minutes rather than distance, because the plan prescribes minutes; and the
/// hard-sessions question is asked outright rather than inferred from fitness level, because
/// ACOG 804's "may continue vigorous activity" allowance keys on exactly that habit.
struct OBPrePregnancyRunningCard: View {
    @Binding var weeklyMinutes: Int
    @Binding var habituallyVigorous: Bool
    /// Called the first time the runner changes the minutes, so onboarding can stop
    /// re-seeding the field from their fitness level.
    var onEditMinutes: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StrideIcon(name: .timer, size: 18, color: .brand)
                Text("BEFORE PREGNANCY")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
            }

            NumericStepperField(
                title: "Weekly running",
                value: $weeklyMinutes,
                range: 0...600,
                step: 15,
                suffix: "min",
                onEdit: { onEditMinutes?() }
            )

            Divider()

            Toggle(isOn: $habituallyVigorous) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("I regularly ran hard sessions")
                        .font(.dsFootnote.weight(.semibold))
                    Text("Intervals, tempo, or racing")
                        .font(.dsCaption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.brand)

            Text("Your plan tapers from these minutes. If you ran hard sessions, you keep one steadier run a week until 28 weeks.")
                .font(.dsCaption2)
                .foregroundStyle(.secondary)
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }
}

// MARK: - OBPregnancyReady

/// The final onboarding screen for a pregnancy plan.
///
/// A separate screen from `OBReady` rather than a mode of it: every stat that one leads with
/// — projected finish time, peak weekly volume, the build-to-peak mileage chart — is
/// meaningless here, and a pregnancy plan's headline numbers are gestational age and the
/// weekly activity floor.
struct OBPregnancyReady: View {
    let planWeeks: Int
    let gestationalAgeAtStart: GestationalAge
    let runDaysPerWeek: Int
    var progressTotal = 8
    let isCreatingPlan: Bool
    let onBack: () -> Void
    let onViewPlan: () -> Void

    private let howItWorks: [(icon: StrideIconName, text: String)] = [
        (.calendar, "You keep running the same number of days. It's the length of each run that comes down."),
        (.timer, "Sessions are set in minutes at a talk-test effort — no pace targets, because pregnancy moves the pace–effort relationship every week."),
        (.walk, "From 28 weeks runs become run/walk by default, and cross-training keeps every week at the 150-minute guideline floor."),
        (.heart, "Pelvic floor work leads every strength session — that part is daily. Nothing is scheduled lying on your back from 16 weeks.")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            MapBackdrop().ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 54)
                HStack(spacing: 14) {
                    Button(action: onBack) {
                        ZStack {
                            Circle()
                                .fill(Color.secondary.opacity(0.1))
                                .frame(width: 32, height: 32)
                            StrideIcon(name: .chevronLeft, size: 14, color: .primary, strokeWeight: 2.4)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isCreatingPlan)
                    .opacity(isCreatingPlan ? 0.4 : 1)
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("onboarding.back.\(progressTotal)")

                    StrideProgressBar(value: 1, height: 4)
                        .accessibilityHidden(true)
                    Text("\(progressTotal)/\(progressTotal)")
                        .font(.dsCaption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, AppSpacing.xl)
                .padding(.top, AppSpacing.sm)
                .padding(.bottom, 22)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("YOUR PLAN")
                                .font(.dsCaption2.weight(.bold))
                                .kerning(1.6)
                                .foregroundStyle(.brandText)
                            Text("\(planWeeks)-week pregnancy plan\nthrough to your due date.")
                                .font(.dsTitle1.weight(.heavy))
                                .kerning(-0.7)
                                .foregroundStyle(.primary)
                                .lineSpacing(-2)
                        }
                        .padding(.horizontal, AppSpacing.xl)

                        HStack(spacing: 0) {
                            OBPregnancyStat(label: "WEEKS", value: "\(planWeeks)")
                            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 36)
                            OBPregnancyStat(label: "AT START", value: gestationalAgeAtStart.noteForm)
                            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 36)
                            OBPregnancyStat(label: "RUN DAYS", value: "\(runDaysPerWeek)")
                        }
                        .padding(AppSpacing.lg)
                        .strideCard(cornerRadius: AppRadius.lg)
                        .padding(.horizontal, AppSpacing.lg)

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(howItWorks, id: \.text) { row in
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
                        .padding(.horizontal, AppSpacing.lg)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("STOP AND CALL YOUR PROVIDER")
                                .strideEyebrow()
                                .foregroundStyle(.destructive)
                            ForEach(PregnancyRedFlag.allCases) { flag in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•").font(.dsCaption).foregroundStyle(.destructive)
                                    Text(flag.localizedText)
                                        .font(.dsCaption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            Text("This list stays on every workout in your plan.")
                                .font(.dsCaption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, AppSpacing.xxs)
                        }
                        .padding(AppSpacing.lg)
                        .background(Color.destructive.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        .padding(.horizontal, AppSpacing.lg)

                        Text(PregnancyRunningPolicy.medicalDisclaimer)
                            .font(.dsCaption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, AppSpacing.xl)

                        Spacer().frame(height: 120)
                    }
                    .padding(.top, AppSpacing.sm)
                }
            }

            Button(action: onViewPlan) {
                Group {
                    if isCreatingPlan {
                        ProgressView().tint(.onFill)
                    } else {
                        HStack(spacing: 10) {
                            Text("Start my plan").font(.dsHeadline.weight(.bold))
                            StrideIcon(name: .chevronRight, size: 15, color: .onFill, strokeWeight: 2.6)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.lg)
                .background(.route, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                .appGlow(.strong, color: .brand)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                )
            }
            .foregroundStyle(.onFill)
            .buttonStyle(.plain)
            .disabled(isCreatingPlan)
            .accessibilityIdentifier("onboarding.startTraining")
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, 44)
        }
    }
}

// MARK: - OBPregnancyStat

private struct OBPregnancyStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.dsCaption2.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.dsTitle2.monospacedDigit())
                .kerning(-0.5)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}
