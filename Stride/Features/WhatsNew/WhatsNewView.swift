import SwiftUI
import UIKit

// MARK: - What's New sheet

/// The release's headline features, one page each with its screenshot, shown once after
/// an update (`WhatsNewPolicy`) and from the TestFlight card in Settings. "All releases"
/// opens the changelog (`ReleaseHistoryView`).
struct WhatsNewView: View {
    let release: Release

    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var appeared = false

    private var isLastPage: Bool { page >= release.features.count - 1 }

    var body: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.lg) {
                header
                    .strideEntrance(appeared)
                TabView(selection: $page) {
                    ForEach(Array(release.features.enumerated()), id: \.element.id) { index, feature in
                        WhatsNewFeaturePage(feature: feature, release: release)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .strideEntrance(appeared, delay: AppAnimation.stagger)
                WhatsNewPageDots(count: release.features.count, current: page)
                Button {
                    if isLastPage {
                        dismiss()
                    } else {
                        withAnimation(AppAnimation.entrance) { page += 1 }
                    }
                } label: {
                    Text(isLastPage ? "Start running" : "Next")
                }
                .buttonStyle(.strideButton(.primary))
                .accessibilityIdentifier("whatsNew.next")
                .padding(.horizontal, AppSpacing.lg)
            }
            .padding(.bottom, AppSpacing.lg)
            .strideReadableWidth()
            .frame(maxWidth: .infinity)
            .background(Color.surfacePrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NavigationLink {
                        ReleaseHistoryView()
                    } label: {
                        Text("All releases")
                    }
                    .accessibilityIdentifier("whatsNew.allReleases")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("whatsNew.done")
                }
            }
            .task { appeared = true }
        }
        .accessibilityIdentifier("whatsNew.sheet")
    }

    private var header: some View {
        VStack(spacing: AppSpacing.xs) {
            Text("What's new in Stride \(release.version)")
                .strideEyebrow()
                .foregroundStyle(Color.brandText)
            Text(release.headline)
                .font(.dsTitle2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppSpacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One feature: its screenshot, then what it is.
private struct WhatsNewFeaturePage: View {
    let feature: ReleaseFeature
    let release: Release

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            ReleaseScreenshot(feature: feature, release: release)
                .frame(maxHeight: .infinity)
            VStack(spacing: AppSpacing.xs) {
                Text(feature.title)
                    .font(.dsTitle3)
                Text(feature.body)
                    .font(.dsCallout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, AppSpacing.xl)
            .accessibilityElement(children: .combine)
        }
        .padding(.bottom, AppSpacing.xs)
    }
}

/// The page dots under the carousel: the current one is a short stretch of route, the rest
/// are `surfaceTertiary` dots. Hidden from VoiceOver, which reads the page itself.
private struct WhatsNewPageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(LinearGradient.route) : AnyShapeStyle(Color.surfaceTertiary))
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .animation(AppAnimation.bouncy, value: current)
        .accessibilityHidden(true)
    }
}

// MARK: - Screenshot

/// A feature's screenshot in a phone-shaped frame, or, when the release has none bundled
/// for it, the feature's icon on the night map in the same frame, so the page never has a
/// hole in it. Screenshots live in `Stride/Resources/WhatsNew.xcassets`, written by the
/// What's New screenshots workflow.
struct ReleaseScreenshot: View {
    let feature: ReleaseFeature
    let release: Release

    /// iPhone screen proportions (1320 × 2868).
    private static let aspectRatio: CGFloat = 1320.0 / 2868.0

    private var image: UIImage? {
        feature.screenshotName(in: release).flatMap { UIImage(named: $0) }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel("Screenshot: \(feature.title)")
            } else {
                ZStack {
                    Rectangle().fill(.inkGround)
                    MapGridPattern(pitch: 28, onInk: true)
                    StrideIcon(name: feature.icon, size: 56, color: .brand, strokeWeight: 2.2)
                }
                .accessibilityHidden(true)
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.cardStroke, lineWidth: 1))
        .appShadow(.e2)
    }
}

// MARK: - Changelog

/// Every release, newest first: Settings → About → What's new in Stride, and "All releases"
/// on the What's New sheet.
struct ReleaseHistoryView: View {
    var releases: [Release] = ReleaseNotes.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                ForEach(releases) { release in
                    NavigationLink {
                        ReleaseNotesView(release: release)
                    } label: {
                        ReleaseHistoryRow(release: release)
                    }
                    .buttonStyle(BouncyButtonStyle())
                    .accessibilityIdentifier("releaseHistory.\(release.version)")
                }
            }
            .padding()
            .strideReadableWidth()
        }
        .background(Color.surfacePrimary)
        .navigationTitle("What's new")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReleaseHistoryRow: View {
    let release: Release

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Stride \(release.version)")
                        .font(.dsHeadline)
                    Spacer()
                    Text(ReleaseNotesFormat.dateLine(release))
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                }
                Text(release.headline)
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(release.features.map(\.title).joined(separator: " · "))
                    .font(.dsFootnote)
                    .foregroundStyle(Color.brandText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            StrideIcon(name: .chevronRight, size: 12, color: Color.secondary.opacity(0.5), strokeWeight: 2)
                .padding(.top, AppSpacing.xs)
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(.primary)
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strideCard()
        .contentShape(Rectangle())
    }
}

/// One release in full: the screenshots, every feature, then the improvements and fixes.
struct ReleaseNotesView: View {
    let release: Release

    private var screenshotFeatures: [ReleaseFeature] {
        release.features.filter { feature in
            feature.screenshotName(in: release).flatMap { UIImage(named: $0) } != nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(ReleaseNotesFormat.dateLine(release))
                        .strideEyebrow()
                        .foregroundStyle(.secondary)
                    Text(release.headline)
                        .font(.dsTitle2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, AppSpacing.xs)

                if !screenshotFeatures.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppSpacing.md) {
                            ForEach(screenshotFeatures) { feature in
                                ReleaseScreenshot(feature: feature, release: release)
                                    .frame(height: 360)
                            }
                        }
                        .padding(.horizontal, AppSpacing.xs)
                        .padding(.vertical, AppSpacing.sm)
                    }
                }

                section("New") {
                    ForEach(Array(release.features.enumerated()), id: \.element.id) { index, feature in
                        if index > 0 { Divider() }
                        featureRow(feature)
                    }
                }
                if !release.improvements.isEmpty {
                    section("Improvements") { bullets(release.improvements) }
                }
                if !release.fixes.isEmpty {
                    section("Fixes") { bullets(release.fixes) }
                }
            }
            .padding()
            .strideReadableWidth()
        }
        .background(Color.surfacePrimary)
        .navigationTitle("Stride \(release.version)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title)
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                content()
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strideCard()
        }
    }

    private func featureRow(_ feature: ReleaseFeature) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.13))
                StrideIcon(name: feature.icon, size: 15, color: .brandText, strokeWeight: 2.2)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(feature.title)
                    .font(.dsHeadline)
                Text(feature.body)
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func bullets(_ lines: [String]) -> some View {
        ForEach(lines, id: \.self) { line in
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                Circle()
                    .fill(.route)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .accessibilityHidden(true)
                Text(line)
                    .font(.bodyRegular)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Formatting

enum ReleaseNotesFormat {
    /// "10 November 2026" once a release is live; "Coming soon" while it is in TestFlight.
    static func dateLine(_ release: Release) -> String {
        guard let components = release.releaseDate,
              let date = Calendar(identifier: .gregorian).date(from: components) else {
            return String(localized: "Coming soon", comment: "Release notes: a release not yet on the App Store")
        }
        return date.formatted(date: .long, time: .omitted)
    }
}

#Preview("What's New") {
    Color.surfacePrimary
        .sheet(isPresented: .constant(true)) {
            WhatsNewView(release: ReleaseNotes.v1point2)
                .strideSheet()
        }
}

#Preview("Release history") {
    NavigationStack { ReleaseHistoryView() }
}
