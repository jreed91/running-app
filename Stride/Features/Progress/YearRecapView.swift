import SwiftData
import SwiftUI

/// The year-in-running recap: a story of cards the runner swipes through and shares.
///
/// Presented full screen. The pager itself is ``RecapStoryPager``, shared with Plan Replay.
struct YearRecapView: View {
    let year: Int

    /// All-time runs, oldest first: best efforts are checked against earlier years and
    /// the distance against last year, so the query can't be limited to `year`.
    @Query(RunWorkout.runsOnlyDescriptor(sortBy: [SortDescriptor(\RunWorkout.date)]))
    private var workouts: [RunWorkout]

    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        let cards = YearRecapCards.make(
            from: YearInRunning.make(from: workouts, year: year),
            unit: appSettings.unitPreference
        )

        RecapStoryPager(cards: cards, logLabel: "Year recap") {
            StrideEmptyState(
                "Your \(String(year)) recap needs a few runs",
                systemImage: "figure.run",
                description: Text("Once you've logged \(YearInRunning.minimumRunsForRecap) runs this year, your recap will be here to look back on and share.")
            )
            .padding(AppSpacing.xl)
        }
    }
}

// MARK: - RecapStoryPager

/// A story of recap cards the runner swipes through and shares, one at a time.
///
/// Each card is the exact view that gets rendered to the shared image
/// (`YearRecapCardView`), scaled to fit the screen, so the share is what they see.
/// Sharing renders only the card on screen, on the tap, the same on-demand rule as the
/// run card (N21).
struct RecapStoryPager<Empty: View>: View {
    let cards: [YearRecapCard]
    /// Names the recap in the log line when a render fails.
    let logLabel: String
    @ViewBuilder let empty: () -> Empty

    @Environment(\.dismiss) private var dismiss

    @State private var selection: YearRecapCard.Kind = .cover
    @State private var shareImage: ShareCardImage?
    /// Cards whose entrance has played. A card animates in the first time it comes on
    /// screen and stays finished after that, so swiping back doesn't replay it.
    @State private var revealedCards: Set<YearRecapCard.Kind> = []

    var body: some View {
        ZStack {
            Rectangle().fill(.inkGround).ignoresSafeArea()

            if cards.isEmpty {
                empty()
            } else {
                VStack(spacing: AppSpacing.lg) {
                    TabView(selection: $selection) {
                        ForEach(cards) { card in
                            RecapScaledCard(card: card, revealed: revealedCards.contains(card.kind))
                                .tag(card.kind)
                                .padding(.horizontal, AppSpacing.lg)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    // The first card plays once the cover is up; each later one as the
                    // swipe lands on it.
                    .task { revealedCards.insert(selection) }
                    .onChange(of: selection) { revealedCards.insert(selection) }

                    Button {
                        share(cards.first { $0.kind == selection } ?? cards[0])
                    } label: {
                        Label("Share this card", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.strideButton())
                    .padding(.horizontal, AppSpacing.xl)
                    .padding(.bottom, AppSpacing.md)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.onInk)
                    .frame(width: 36, height: 36)
                    .background(Color.onInk.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Close")
            .padding(.trailing, AppSpacing.lg)
            .padding(.top, AppSpacing.sm)
        }
        .environment(\.colorScheme, .dark)
        .sheet(item: $shareImage) { card in
            ShareSheet(image: card.image)
        }
    }

    /// Renders one card at ×3 (1080×1920) and opens the share sheet.
    private func share(_ card: YearRecapCard) {
        let renderer = ImageRenderer(content: YearRecapCardView(card: card))
        renderer.scale = 3
        guard let image = renderer.uiImage else {
            AppLogger.log("\(logLabel) card render produced no image", label: "Share", level: .error)
            return
        }
        shareImage = ShareCardImage(image: image)
    }
}

/// A recap card at its design size, scaled down to fit the space it's given and kept at
/// the card's 9:16 shape. Scaling the fixed-size view (rather than laying it out again at
/// a new size) keeps the on-screen card identical to the shared image.
struct RecapScaledCard: View {
    let card: YearRecapCard
    let revealed: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = YearRecapCardView.size
            let scale = min(proxy.size.width / size.width, proxy.size.height / size.height)
            YearRecapCardView(card: card, revealed: revealed, isLive: true)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg / max(scale, 0.01), style: .continuous))
                .scaleEffect(scale)
                .frame(width: size.width * scale, height: size.height * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityText)
    }
}
