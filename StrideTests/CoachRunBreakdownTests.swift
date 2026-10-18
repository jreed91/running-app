import Testing
import Foundation
@testable import Stride

private func split(
    _ index: Int,
    pace: Double,
    hr: Double? = nil,
    elevation: Double = 0
) -> Split {
    Split(
        kilometer: index,
        paceSecondsPerKm: pace,
        heartRate: hr,
        elevationGainMeters: elevation,
        cumulativeDistanceMeters: Double(index) * 1_000
    )
}

struct CoachRunBreakdownTests {

    // MARK: Split section

    @Test("Split section lists every split with the run's own bucket label")
    func splitSectionListsSplits() {
        let splits = [
            split(1, pace: 300, hr: 140, elevation: 12),
            split(2, pace: 310, hr: 148)
        ]

        let section = CoachRunBreakdown.splitSection(splits: splits, unit: .metric, splitLabel: "km")

        #expect(section.contains("km 1: pace 5:00 min/km, hr 140, elev 12 m"))
        #expect(section.contains("km 2: pace 5:10 min/km, hr 148, elev 0 m"))
        #expect(section.components(separatedBy: "\n").count == 2)
    }

    @Test("Split section reports no data for a run without splits")
    func splitSectionWithoutSplits() {
        #expect(CoachRunBreakdown.splitSection(splits: [], unit: .metric, splitLabel: "km") == "No split data.")
    }

    @Test("Long runs keep their opening and closing splits and drop the middle")
    func splitSectionTruncatesMiddle() {
        let splits = (1...42).map { split($0, pace: 300 + Double($0)) }

        let section = CoachRunBreakdown.splitSection(
            splits: splits,
            unit: .metric,
            splitLabel: "km",
            limit: 10
        )
        let lines = section.components(separatedBy: "\n")

        // 5 opening + omission note + 5 closing.
        #expect(lines.count == 11)
        #expect(lines.first?.hasPrefix("km 1:") == true)
        #expect(lines.last?.hasPrefix("km 42:") == true)
        #expect(section.contains("(32 middle splits omitted)"))
        #expect(section.contains("km 20:") == false)
    }

    @Test("Imperial splits are labelled and formatted per mile")
    func splitSectionImperial() {
        let section = CoachRunBreakdown.splitSection(
            splits: [split(1, pace: 300, hr: 150, elevation: 10)],
            unit: .imperial,
            splitLabel: "mi"
        )

        #expect(section.contains("mi 1:"))
        #expect(section.contains("8:02 min/mi"))
        #expect(section.contains("33 ft"))
    }

    // MARK: Split trend

    @Test("Split trend finds the extremes, spread, consistency, and a negative split")
    func splitTrendNegativeSplit() throws {
        let splits = [
            split(1, pace: 320),
            split(2, pace: 315),
            split(3, pace: 300),
            split(4, pace: 290)
        ]

        let trend = try #require(CoachRunBreakdown.splitTrend(splits: splits, unit: .metric))

        #expect(trend.fastest.kilometer == 4)
        #expect(trend.slowest.kilometer == 1)
        #expect(trend.spreadSeconds == 30)
        // (300 + 290)/2 - (320 + 315)/2 = -22.5
        #expect(trend.secondHalfDeltaSeconds == -22.5)
        #expect(trend.consistencySeconds > 0)

        let sentence = CoachRunBreakdown.splitTrendSentence(trend, splitLabel: "km", unit: .metric)
        #expect(sentence.contains("negative split"))
        #expect(sentence.contains("4:50 min/km"))
    }

    @Test("A fading run reads as a positive split")
    func splitTrendPositiveSplit() throws {
        let splits = [
            split(1, pace: 290),
            split(2, pace: 295),
            split(3, pace: 320),
            split(4, pace: 330)
        ]

        let trend = try #require(CoachRunBreakdown.splitTrend(splits: splits, unit: .metric))
        let line = CoachRunBreakdown.splitTrendLine(trend, splitLabel: "km", unit: .metric)

        #expect(trend.secondHalfDeltaSeconds > 0)
        #expect(line.contains("positive split"))
        #expect(line.contains("fastest km 1"))
        #expect(line.contains("slowest km 4"))
    }

    @Test("An even run is not described as a split in either direction")
    func splitTrendEvenRun() throws {
        let splits = [
            split(1, pace: 300),
            split(2, pace: 301),
            split(3, pace: 299),
            split(4, pace: 300)
        ]

        let trend = try #require(CoachRunBreakdown.splitTrend(splits: splits, unit: .metric))
        let sentence = CoachRunBreakdown.splitTrendSentence(trend, splitLabel: "km", unit: .metric)

        #expect(sentence.contains("held the first-half pace"))
        #expect(sentence.contains("split)") == false)
    }

    @Test("Trend second values convert to the display unit")
    func splitTrendImperialSeconds() throws {
        let splits = [split(1, pace: 300), split(2, pace: 360)]

        let metric = try #require(CoachRunBreakdown.splitTrend(splits: splits, unit: .metric))
        let imperial = try #require(CoachRunBreakdown.splitTrend(splits: splits, unit: .imperial))

        #expect(metric.spreadSeconds == 60)
        #expect(abs(imperial.spreadSeconds - 60 * 1.60934) < 0.001)
    }

    @Test("A single split is not enough for a trend")
    func splitTrendNeedsTwoSplits() {
        #expect(CoachRunBreakdown.splitTrend(splits: [split(1, pace: 300)], unit: .metric) == nil)
        #expect(CoachRunBreakdown.splitTrend(splits: [], unit: .metric) == nil)
    }

    @Test("Splits with no recorded pace are ignored by the trend")
    func splitTrendSkipsZeroPaceSplits() throws {
        let splits = [split(1, pace: 0), split(2, pace: 300), split(3, pace: 320)]

        let trend = try #require(CoachRunBreakdown.splitTrend(splits: splits, unit: .metric))

        #expect(trend.fastest.kilometer == 2)
        #expect(trend.slowest.kilometer == 3)
    }

    // MARK: Heart-rate zones

    private var sampleZones: [HRZoneSlice] {
        [
            HRZoneSlice(zone: .z1, seconds: 0),
            HRZoneSlice(zone: .z2, seconds: 1_200),
            HRZoneSlice(zone: .z3, seconds: 600),
            HRZoneSlice(zone: .z4, seconds: 180),
            HRZoneSlice(zone: .z5, seconds: 20)
        ]
    }

    @Test("Zone section lists the zones the runner entered, hardest first, with bpm bounds")
    func zoneSectionOrdersHardestFirst() {
        let section = CoachRunBreakdown.zoneSection(sampleZones, maxHR: 190)
        let lines = section.components(separatedBy: "\n")

        #expect(lines.first == "Zones derived from max HR 190 bpm.")
        #expect(lines[1].hasPrefix("Z5 Max (171-190 bpm): 0:20"))
        #expect(lines[2].hasPrefix("Z4 Threshold (152-171 bpm): 3:00"))
        #expect(lines[3].hasPrefix("Z3 Aerobic (133-152 bpm): 10:00"))
        #expect(lines[4].hasPrefix("Z2 Easy (114-133 bpm): 20:00"))
        // Z1 was never entered, so it is left out rather than padding the prompt.
        #expect(section.contains("Z1") == false)
        #expect(section.contains("(60%)"))
    }

    @Test("Zone section says the zones are approximate when max HR is age-estimated")
    func zoneSectionWithEstimatedMaxHR() {
        let section = CoachRunBreakdown.zoneSection(sampleZones, maxHR: 186, maxHRIsEstimated: true)
        let header = section.components(separatedBy: "\n").first

        #expect(header?.hasPrefix("Zones derived from max HR 186 bpm, estimated from age") == true)
        #expect(header?.contains("approximate") == true)
    }

    @Test("Zone section omits bpm bounds when max HR is unknown")
    func zoneSectionWithoutMaxHR() {
        let section = CoachRunBreakdown.zoneSection(sampleZones, maxHR: nil)

        #expect(section.contains("bpm") == false)
        #expect(section.hasPrefix("Z5 Max: 0:20"))
    }

    @Test("Zone section reports no data when nothing was recorded")
    func zoneSectionWithoutData() {
        #expect(CoachRunBreakdown.zoneSection([], maxHR: 190) == "No heart-rate zone data.")
        let allZero = HRZone.allCases.map { HRZoneSlice(zone: $0, seconds: 0) }
        #expect(CoachRunBreakdown.zoneSection(allZero, maxHR: 190) == "No heart-rate zone data.")
    }

    @Test("Zone sentence names the dominant zone and the hard share")
    func zoneSentenceNamesDominantZone() throws {
        let sentence = try #require(CoachRunBreakdown.zoneSentence(sampleZones))

        #expect(sentence.contains("Z2"))
        #expect(sentence.contains("60%"))
        #expect(sentence.contains("10% at threshold or harder"))
    }

    @Test("Zone sentence leaves out the hard share when there is none")
    func zoneSentenceWithoutHardTime() throws {
        let zones = [
            HRZoneSlice(zone: .z1, seconds: 60),
            HRZoneSlice(zone: .z2, seconds: 540),
            HRZoneSlice(zone: .z3, seconds: 0),
            HRZoneSlice(zone: .z4, seconds: 0),
            HRZoneSlice(zone: .z5, seconds: 0)
        ]

        let sentence = try #require(CoachRunBreakdown.zoneSentence(zones))

        #expect(sentence.contains("threshold") == false)
        #expect(CoachRunBreakdown.zoneSentence([]) == nil)
    }

    @Test("Hard-effort share counts Z4 and Z5 only")
    func hardEffortShare() throws {
        let share = try #require(CoachRunBreakdown.hardEffortShare(sampleZones))

        #expect(abs(share - 200.0 / 2_000.0) < 0.0001)
        #expect(CoachRunBreakdown.hardEffortShare([]) == nil)
    }

    // MARK: Cadence (A5)

    @Test("Cadence sentence reports the number, and flags only a low one")
    func cadenceSentence() throws {
        let healthy = try #require(CoachRunBreakdown.cadenceSentence(176.4))
        #expect(healthy == "Average cadence was 176 steps per minute.")
        #expect(healthy.contains("low") == false)

        let low = try #require(CoachRunBreakdown.cadenceSentence(151.6))
        #expect(low.contains("152 steps per minute"))
        #expect(low.contains("low side"))
        #expect(low.contains("overstriding"))
    }

    @Test("Cadence sentence is absent when the run recorded none")
    func cadenceSentenceWithoutData() {
        #expect(CoachRunBreakdown.cadenceSentence(nil) == nil)
        #expect(CoachRunBreakdown.cadenceSentence(0) == nil)
        #expect(CoachRunBreakdown.cadenceSentence(.infinity) == nil)
    }

    @Test("Cadence focus is given only for a low cadence on an aerobic run")
    func cadenceFocusIsScoped() throws {
        // Low, on the two session types where changing something about form is free.
        #expect(CoachRunBreakdown.cadenceFocus(150, workoutType: .easy) != nil)
        #expect(CoachRunBreakdown.cadenceFocus(150, workoutType: .longRun) != nil)

        // Low, but on a session with a target of its own — not the day to fiddle with form.
        #expect(CoachRunBreakdown.cadenceFocus(150, workoutType: .interval) == nil)
        #expect(CoachRunBreakdown.cadenceFocus(150, workoutType: .race) == nil)

        // Fine, or missing — nothing to say either way.
        #expect(CoachRunBreakdown.cadenceFocus(178, workoutType: .easy) == nil)
        #expect(CoachRunBreakdown.cadenceFocus(nil, workoutType: .easy) == nil)

        let focus = try #require(CoachRunBreakdown.cadenceFocus(150, workoutType: .easy))
        #expect(focus.contains("150 spm"))
    }
}
