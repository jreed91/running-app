import SwiftUI

// MARK: - OBWelcome

struct OBWelcome: View {
    let onStart: () -> Void

    private let brandGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 1.0, green: 0.42, blue: 0.133), location: 0),
            .init(color: Color(red: 0.878, green: 0.263, blue: 0.102), location: 1),
        ],
        startPoint: UnitPoint(x: 0.1, y: 0),
        endPoint: UnitPoint(x: 0.9, y: 1)
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            brandGradient.ignoresSafeArea()
            RadialGradient(colors: [.white.opacity(0.18), .clear],
                           center: .init(x: 0.1, y: 0.05), startRadius: 0, endRadius: 280)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer().frame(height: 72)

                        // App mark
                        ZStack {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(.white.opacity(0.18))
                                .overlay(RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                                .frame(width: 84, height: 84)
                            StrideIcon(name: .run, size: 44, color: .white, strokeWeight: 2.0)
                        }

                        Spacer().frame(height: 28)

                        Text("WELCOME TO STRIDE")
                            .font(.system(size: 13, weight: .bold))
                            .kerning(1.8)
                            .foregroundStyle(.white.opacity(0.85))

                        Spacer().frame(height: 10)

                        Text("Train for your\nnext finish line.")
                            .font(.system(size: 44, weight: .heavy))
                            .kerning(-1.5)
                            .foregroundStyle(.white)
                            .lineSpacing(2)

                        Spacer().frame(height: 20)

                        Text("Adaptive plans for 5K, Half, and Marathon — built around the pace you run today.")
                            .font(.bodyRegular)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineSpacing(3)

                        Spacer().frame(height: 36)

                        VStack(spacing: 14) {
                            OBFeatureRow(icon: .chart, title: "VDOT-based pacing",
                                         sub: "Training paces from your 5K time")
                            OBFeatureRow(icon: .calendar, title: "Adaptive plans",
                                         sub: "80/20 easy/quality, progressive build")
                            OBFeatureRow(icon: .heart, title: "Syncs with HealthKit",
                                         sub: "Pulls runs, tracks workouts")
                        }

                        Spacer().frame(height: 120)
                    }
                    .padding(.horizontal, 28)
                }

                // CTA pinned at bottom
                Button(action: onStart) {
                    HStack(spacing: 10) {
                        Text("Get Started")
                            .font(.system(size: 17, weight: .bold))
                        StrideIcon(name: .chevronRight, size: 14, color: .brand, strokeWeight: 2.6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                }
                .foregroundStyle(Color.brand)
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 44)
            }
        }
        .foregroundStyle(.white)
    }
}

// MARK: - OBFeatureRow

private struct OBFeatureRow: View {
    let icon: StrideIconName
    let title: String
    let sub: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                    .frame(width: 40, height: 40)
                StrideIcon(name: icon, size: 20, color: .white, strokeWeight: 2.2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bodyStrong).foregroundStyle(.white)
                Text(sub).font(.caption).foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
        }
    }
}

// MARK: - OBShell

struct OBShell<Content: View>: View {
    let stepIndex: Int
    let total: Int
    let kicker: String
    let title: String
    let subtitle: String
    let ctaLabel: String
    var ctaEnabled: Bool = true
    let onBack: () -> Void
    let onCTA: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.surfacePrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress chrome
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

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 4)
                                Capsule().fill(Color.brand)
                                    .frame(width: geo.size.width * CGFloat(stepIndex + 1) / CGFloat(total),
                                           height: 4)
                                    .animation(.easeInOut(duration: 0.3), value: stepIndex)
                            }
                        }
                        .frame(height: 4)

                        Text("\(stepIndex + 1)/\(total)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text(kicker.uppercased())
                                .font(.system(size: 12, weight: .bold))
                                .kerning(1.6)
                                .foregroundStyle(.brand)
                            Text(title)
                                .font(.system(size: 32, weight: .heavy))
                                .kerning(-0.8)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.bodyRegular)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                        }

                        content()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 120)
                }
            }

            // CTA pinned at bottom
            Button(action: onCTA) {
                HStack(spacing: 10) {
                    Text(ctaLabel).font(.system(size: 17, weight: .bold))
                    StrideIcon(name: .chevronRight, size: 14, color: .white, strokeWeight: 2.6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.brand.opacity(ctaEnabled ? 1 : 0.5),
                            in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: Color.brand.opacity(ctaEnabled ? 0.4 : 0), radius: 12, y: 6)
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .disabled(!ctaEnabled)
            .padding(.horizontal, 20)
            .padding(.bottom, 44)
        }
    }
}

// MARK: - OBRaceCard

struct OBRaceCard: View {
    let race: RaceType
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(AppSettings.self) private var appSettings

    private var color: Color {
        switch race {
        case .fiveK: return .zoneInterval
        case .halfMarathon: return .zoneTempo
        case .marathon: return .zoneEasy
        }
    }
    private var icon: StrideIconName {
        switch race {
        case .fiveK: return .bolt
        case .halfMarathon: return .tempo
        case .marathon: return .run
        }
    }
    private var distanceLabel: String {
        let isImperial = appSettings.unitPreference == .imperial
        switch race {
        case .fiveK:         return isImperial ? "3.1 mi"  : "5.0 km"
        case .halfMarathon:  return isImperial ? "13.1 mi" : "21.1 km"
        case .marathon:      return isImperial ? "26.2 mi" : "42.2 km"
        }
    }
    private var desc: String {
        switch race {
        case .fiveK: return "Fast, speed-focused plans"
        case .halfMarathon: return "Endurance with tempo work"
        case .marathon: return "Long-run focused, biggest build"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(color.opacity(0.15)).frame(width: 48, height: 48)
                    StrideIcon(name: icon, size: 22, color: color, strokeWeight: 2.2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(race.displayName).font(.bodyStrong)
                        Text(distanceLabel)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(desc) · \(race.typicalWeeks.lowerBound)–\(race.typicalWeeks.upperBound) wks")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                OBRadio(isSelected: isSelected, color: color)
            }
            .padding(16)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isSelected ? color : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
    }
}

// MARK: - OBLevelRow

struct OBLevelRow: View {
    let level: FitnessLevel
    let race: RaceType
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(AppSettings.self) private var appSettings

    private var desc: String {
        switch level {
        case .beginner: return "New to running or returning"
        case .intermediate: return "Comfortable running 3× per week"
        case .advanced: return "Consistent weekly mileage"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(level.displayName).font(.bodyStrong)
                    Text(desc)
                        .font(.caption).foregroundStyle(.secondary)
                    Text({
                        let km = level.startingWeeklyKm(for: race)
                        if appSettings.unitPreference == .imperial {
                            return String(format: "%.0f mi/wk base", km * 0.621371)
                        }
                        return String(format: "%.0f km/wk base", km)
                    }())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                OBRadio(isSelected: isSelected, color: .brand)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isSelected ? Color.brand : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
    }
}

// MARK: - OBPaceCell

struct OBPaceCell: View {
    let zone: String
    let color: Color
    let pace: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(zone.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(color)
                Text(pace)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - OBPermissionRow

struct OBPermissionRow: View {
    let icon: StrideIconName
    let label: String
    let desc: String
    let tint: Color
    let isOn: Bool
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint.opacity(isActive ? 0.25 : 0.15))
                    .frame(width: 40, height: 40)
                StrideIcon(name: icon, size: 20, color: tint, strokeWeight: 2.2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.bodyStrong)
                Text(isActive ? "Requesting access…" : desc)
                    .font(.caption).foregroundStyle(isActive ? tint : .secondary)
                    .animation(.easeInOut(duration: 0.2), value: isActive)
            }
            Spacer()
            Group {
                if isActive {
                    ProgressView().tint(tint)
                        .frame(width: 28, height: 28)
                } else if isOn {
                    ZStack {
                        Circle().fill(Color.success)
                            .frame(width: 28, height: 28)
                        StrideIcon(name: .check, size: 13, color: .white, strokeWeight: 3)
                    }
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 28, height: 28)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isActive)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isOn)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - OBRadio

struct OBRadio: View {
    let isSelected: Bool
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? color : Color.secondary.opacity(0.35), lineWidth: 2)
                .frame(width: 22, height: 22)
            if isSelected {
                Circle().fill(color).frame(width: 22, height: 22)
                StrideIcon(name: .check, size: 12, color: .white, strokeWeight: 3)
            }
        }
    }
}

// MARK: - OBReady

struct OBReady: View {
    let goalRace: RaceType
    let planWeeks: Int
    let estimatedWorkouts: Int
    let estimatedKm: Int
    let isCreatingPlan: Bool
    let onViewPlan: () -> Void

    @Environment(AppSettings.self) private var appSettings

    private let brandGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 1.0, green: 0.42, blue: 0.133), location: 0),
            .init(color: Color(red: 0.878, green: 0.263, blue: 0.102), location: 1),
        ],
        startPoint: UnitPoint(x: 0.1, y: 0),
        endPoint: UnitPoint(x: 0.9, y: 1)
    )

    private let phaseColors: [(String, Color, Double)] = [
        ("Base", .zoneEasy, 0.375),
        ("Build", .zoneTempo, 0.313),
        ("Peak", .brand, 0.188),
        ("Taper", .zoneInterval, 0.124),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            brandGradient.ignoresSafeArea()
            RadialGradient(colors: [.white.opacity(0.18), .clear],
                           center: .init(x: 0.1, y: 0.05), startRadius: 0, endRadius: 280)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer().frame(height: 72)

                        // Checkmark circle
                        ZStack {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(.white.opacity(0.18))
                                .overlay(RoundedRectangle(cornerRadius: 24)
                                    .strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                                .frame(width: 96, height: 96)
                            StrideIcon(name: .check, size: 44, color: .white, strokeWeight: 2.6)
                        }

                        Spacer().frame(height: 24)

                        Text("YOUR PLAN IS READY")
                            .font(.system(size: 13, weight: .bold))
                            .kerning(1.8)
                            .foregroundStyle(.white.opacity(0.85))

                        Spacer().frame(height: 10)

                        Text("\(planWeeks) weeks to your\n\(goalRace.displayName).")
                            .font(.system(size: 40, weight: .heavy))
                            .kerning(-1.5)
                            .foregroundStyle(.white)
                            .lineSpacing(2)

                        Spacer().frame(height: 24)

                        // Stat boxes
                        HStack(spacing: 10) {
                            OBStatBox(value: "\(planWeeks)", label: "WEEKS")
                            OBStatBox(value: "\(estimatedWorkouts)", label: "WORKOUTS")
                            OBStatBox(value: {
                                if appSettings.unitPreference == .imperial {
                                    return "\(Int((Double(estimatedKm) * 0.621371).rounded())) mi"
                                }
                                return "\(estimatedKm) km"
                            }(), label: "TOTAL")
                        }

                        Spacer().frame(height: 22)

                        // Phase bar card
                        VStack(alignment: .leading, spacing: 12) {
                            Text("PHASES")
                                .font(.sectionHeader)
                                .foregroundStyle(.white.opacity(0.72))

                            GeometryReader { geo in
                                HStack(spacing: 0) {
                                    ForEach(phaseColors, id: \.0) { _, color, fraction in
                                        color.frame(width: geo.size.width * fraction)
                                    }
                                }
                                .clipShape(Capsule())
                            }
                            .frame(height: 12)

                            HStack {
                                ForEach(phaseColors, id: \.0) { name, _, fraction in
                                    Text("\(name) · \(Int(Double(planWeeks) * fraction))w")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.8))
                                    if name != "Taper" { Spacer() }
                                }
                            }
                        }
                        .padding(18)
                        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))

                        Spacer().frame(height: 120)
                    }
                    .padding(.horizontal, 28)
                }
            }

            // CTA
            Button(action: onViewPlan) {
                Group {
                    if isCreatingPlan {
                        ProgressView().tint(Color.brand)
                    } else {
                        HStack(spacing: 10) {
                            Text("View My Plan").font(.system(size: 17, weight: .bold))
                            StrideIcon(name: .chevronRight, size: 14, color: .brand, strokeWeight: 2.6)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            }
            .foregroundStyle(Color.brand)
            .buttonStyle(.plain)
            .disabled(isCreatingPlan)
            .padding(.horizontal, 20)
            .padding(.bottom, 44)
        }
        .foregroundStyle(.white)
    }
}

// MARK: - OBStatBox

private struct OBStatBox: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
            Text(label)
                .font(.sectionHeader)
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
    }
}
