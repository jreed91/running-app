import Foundation
import Testing
@testable import Stride

/// Covers the spoken form of a metric cell (N18), now shared by the run HUD, the run
/// detail stats grid, and the Progress period summary rather than living in one view.
struct SpokenMetricTests {

    @Test("Abbreviated units are spelled out")
    func unitsAreSpelledOut() {
        #expect(SpokenMetric.spoken(value: "142", unit: "bpm") == "142 beats per minute")
        #expect(SpokenMetric.spoken(value: "168", unit: "spm") == "168 steps per minute")
        #expect(SpokenMetric.spoken(value: "4:32", unit: "/km") == "4:32 per kilometre")
        #expect(SpokenMetric.spoken(value: "320", unit: "ft") == "320 feet")
    }

    @Test("An unrecognised unit is spoken as written")
    func unknownUnitPassesThrough() {
        #expect(SpokenMetric.spoken(value: "12", unit: "sets") == "12 sets")
    }

    @Test("A value with no unit is spoken alone")
    func noUnit() {
        #expect(SpokenMetric.spoken(value: "48.5") == "48.5")
    }

    /// A cell with nothing to show renders dashes, which VoiceOver otherwise reads as
    /// "dash dash" or as a pause.
    @Test("Dash placeholders are spoken as no data")
    func placeholdersAreSpoken() {
        #expect(SpokenMetric.spoken(value: "--", unit: "bpm") == "No data yet")
        #expect(SpokenMetric.spoken(value: "--:--") == "No data yet")
        #expect(SpokenMetric.spoken(value: " ") == "No data yet")
        #expect(!SpokenMetric.isPlaceholder("0:00"))
    }

    @Test("A value carrying its unit inline has the trailing unit translated")
    func inlineUnitIsTranslated() {
        #expect(SpokenMetric.spoken(measurement: "5.2 km") == "5.2 kilometres")
        #expect(SpokenMetric.spoken(measurement: "4:32 min/mi") == "4:32 minutes per mile")
        #expect(SpokenMetric.spoken(measurement: "--") == "No data yet")
    }

    @Test("A value whose trailing word is not a unit is left alone")
    func inlineNonUnitIsUntouched() {
        #expect(SpokenMetric.spoken(measurement: "3 runs") == "3 runs")
        #expect(SpokenMetric.spoken(measurement: "48.5") == "48.5")
    }
}
