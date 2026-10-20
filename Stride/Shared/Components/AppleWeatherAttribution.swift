import SwiftUI
import WeatherKit

// MARK: - AppleWeatherAttribution

/// The Apple Weather mark and the legal-sources link that WeatherKit's terms require
/// wherever its data is shown (App Review guideline 5.2.5).
///
/// One line, placed under the weather it credits: the run summary's conditions row, the
/// History list, the race weather card and both heat advisory surfaces. The mark and the
/// link come from `WeatherService.shared.attribution`, fetched once per launch. Until that
/// answers, or when it cannot (offline, simulator), the line falls back to the text mark
/// " Weather" and Apple's published legal page, so the credit is never missing.
struct AppleWeatherAttribution: View {

    @Environment(\.colorScheme) private var colorScheme
    @State private var attribution: WeatherKit.WeatherAttribution?

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            mark
            if let legalURL = attribution?.legalPageURL ?? Self.fallbackLegalURL {
                Link(
                    String(localized: "Other data sources", comment: "Link to Apple Weather's legal attribution page"),
                    destination: legalURL
                )
                .underline()
            }
        }
        .font(.dsCaption2)
        .foregroundStyle(.secondary)
        .task { attribution = await AppleWeatherAttributionCache.load() }
    }

    @ViewBuilder
    private var mark: some View {
        let url = colorScheme == .dark ? attribution?.combinedMarkDarkURL : attribution?.combinedMarkLightURL
        if let url {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(height: 12)
                } else {
                    textMark
                }
            }
            .accessibilityLabel(attribution?.serviceName ?? "Apple Weather")
        } else {
            textMark
        }
    }

    /// U+F8FF is the Apple logo in Apple's system fonts; Apple's attribution guidelines
    /// accept " Weather" as text where the image mark is not available.
    private var textMark: some View {
        Text(verbatim: "\u{F8FF} Weather")
            .fontWeight(.semibold)
            .accessibilityLabel("Apple Weather")
    }

    /// Apple's published WeatherKit legal attribution page, used until the live
    /// attribution answers.
    static let fallbackLegalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")
}

// MARK: - Cache

/// The attribution changes about as often as Apple's legal page does, so one request per
/// launch serves every card that shows it.
@MainActor
private enum AppleWeatherAttributionCache {
    static var value: WeatherKit.WeatherAttribution?

    static func load() async -> WeatherKit.WeatherAttribution? {
        if let value { return value }
        do {
            let fetched = try await WeatherKit.WeatherService.shared.attribution
            value = fetched
            return fetched
        } catch {
            AppLogger.log(
                "Weather attribution unavailable, showing the text mark: \(error.localizedDescription)",
                label: "WeatherKit",
                level: .debug
            )
            return nil
        }
    }
}
