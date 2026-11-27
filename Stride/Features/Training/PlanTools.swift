import SwiftUI

// Plan's tools: Smart Adapt, the two insights pages and Train with friends. They were four
// full-width cards between this week and the rest of the season, which pushed the weeks
// a screen down; they are now one grid of small tiles under a "Plan tools" eyebrow.

// MARK: - Grid

/// Two tiles a row, one at accessibility text sizes so a tile's title never truncates.
struct PlanToolsGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    private let content: Content

    /// Built here, in the caller's body, not later in this view's: the tiles' pages read
    /// Plan's `@Query` results, which must be read inside Plan's body.
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var columnCount: Int { typeSize.isAccessibilitySize ? 1 : 2 }

    /// An eager `Grid`, not a `LazyVGrid`. With five tiles there is nothing to save by
    /// building lazily, and the lazy grid left the fifth tile (My workouts, alone on the
    /// third row, below the fold) out of the accessibility tree even once it was scrolled
    /// on screen: UI tests could not find it (CI runs 46071560695 and 46075739921), so
    /// VoiceOver most likely could not reach it either.
    var body: some View {
        Group(subviews: content) { tiles in
            let columns = columnCount
            Grid(horizontalSpacing: AppSpacing.md, verticalSpacing: AppSpacing.md) {
                ForEach(Array(stride(from: 0, to: tiles.count, by: columns)), id: \.self) { start in
                    GridRow(alignment: .top) {
                        ForEach(start..<(start + columns), id: \.self) { index in
                            if index < tiles.count {
                                tiles[index]
                            } else {
                                // Holds the odd tile to half the width, as the lazy grid did.
                                Color.clear
                                    .gridCellUnsizedAxes(.vertical)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Tile

/// One tool: a 32 pt icon tile, a title and a short line under it. A minimum height keeps
/// a row's tiles level when one subtitle wraps and the other doesn't.
struct PlanToolTile<Icon: View>: View {
    let title: LocalizedStringKey
    let subtitle: String
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            icon()
                .frame(width: 32, height: 32)
                .background(Color.brand.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.dsSubhead.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(AppSpacing.md)
        .strideCard()
        .contentShape(.rect(cornerRadius: AppRadius.lg))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

extension PlanToolTile where Icon == StrideIcon {
    init(title: LocalizedStringKey, subtitle: String, glyph: StrideIconName) {
        self.init(title: title, subtitle: subtitle) {
            StrideIcon(name: glyph, size: 16, color: .brand, strokeWeight: 2)
        }
    }
}

// MARK: - Smart Adapt

/// Smart Adapt as a tile. It runs in place rather than opening a page, so the tile is a
/// button; its progress and outcome show in `SmartAdaptProgressPanel` under the grid.
struct SmartAdaptTile: View {
    let workoutCount: Int
    let state: SmartAdaptState
    let unavailableReason: String?
    let action: () -> Void

    private var isAdapting: Bool { state.isRunning }

    private var isEnabled: Bool {
        workoutCount > 0 && unavailableReason == nil && !isAdapting
    }

    /// When Smart Adapt can't run, the reason is the subtitle, inside the tile.
    private var subtitle: String {
        if isAdapting { return "Adapting your plan" }
        if let unavailableReason { return unavailableReason }
        guard workoutCount > 0 else { return "No run workouts left to adapt" }
        let label = workoutCount == 1 ? "workout" : "workouts"
        return "Adapt the next \(workoutCount) \(label)"
    }

    var body: some View {
        Button(action: action) {
            PlanToolTile(title: "Smart Adapt", subtitle: subtitle) {
                if isAdapting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    // No sparkles in StrideIconName.
                    Image(systemName: "sparkles")
                        .font(.dsCallout.weight(.semibold))
                        .foregroundStyle(.brand)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // Not `.opacity(0.55)`: that multiplied into the `.secondary` subtitle and read
        // as broken. Grey accent signals "off"; the reason stays readable.
        .grayscale(isEnabled ? 0 : 1)
        .opacity(isEnabled ? 1 : 0.9)
        .accessibilityIdentifier("plan.smartAdaptTile")
    }
}

/// Smart Adapt's progress, live summary and outcome. It stays until the next run
/// (`SmartAdaptState`), full width under the tools grid.
struct SmartAdaptProgressPanel: View {
    let state: SmartAdaptState

    private var progress: SmartAdaptProgress { state.progress }

    var body: some View {
        if state.showsProgress {
            VStack(alignment: .leading, spacing: 8) {
                if state.isRunning {
                    if let value = progress.fractionCompleted {
                        StrideProgressBar(value: value)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text(progress.currentMessage)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)

                if !progress.streamingSummaries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Live summary")
                            .font(.captionStrong)
                            .foregroundStyle(.primary)

                        ForEach(progress.streamingSummaries, id: \.self) { summary in
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(Color.brand)
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 6)
                                Text(summary)
                                    .font(.dsCaption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .padding(AppSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .strideCard(cornerRadius: AppRadius.sm)
                }

                ForEach(progress.updates) { update in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(update.title)
                            .font(.captionStrong)
                            .foregroundStyle(.primary)
                        Text(update.message)
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(AppSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .strideCard(cornerRadius: AppRadius.sm)
                }
            }
            .padding(.horizontal, AppSpacing.xs)
        }
    }
}
