import Testing
import Foundation
@testable import Stride

// MARK: - Share card formats and plan context
//
// The shapes a run card is exported in, and the plan line that tells a friend the run
// was part of a plan.

struct ShareCardFormatTests {

    @Test("Each format exports at the size its platform expects")
    func pixelSizes() {
        #expect(ShareCardFormat.story.pixelSize == CGSize(width: 1080, height: 1920))
        #expect(ShareCardFormat.portrait.pixelSize == CGSize(width: 1080, height: 1350))
        #expect(ShareCardFormat.square.pixelSize == CGSize(width: 1080, height: 1080))
    }

    @Test("Route panels fit inside the card with 20 pt each side")
    func routePanelsFit() {
        for format in ShareCardFormat.allCases {
            #expect(format.routePanelSize.width <= format.size.width - 40)
            #expect(format.routePanelSize.height < format.size.height)
        }
    }

    @Test("Only the sticker is transparent and mapless")
    func stickerIsTransparent() {
        for format in ShareCardFormat.allCases {
            #expect(format.isTransparent == (format == .sticker))
            #expect(format.showsMap == (format != .sticker))
        }
    }

    @Test("The old card's sizes are the portrait format's")
    func portraitMatchesOriginal() {
        #expect(ShareCardFormat.portrait.size == CGSize(width: 360, height: 450))
        #expect(ShareCardFormat.portrait.routePanelSize == CGSize(width: 320, height: 150))
    }

    // MARK: Plan context

    @Test("Plan context names the week and the plan")
    func planContextLine() {
        let line = ShareCardModel.planContext(
            weekNumber: 6, totalWeeks: 16, planTitle: "Half Marathon", isPregnancyPlan: false
        )
        #expect(line == "Week 6 of 16 · Half Marathon")
    }

    @Test("Plan context without a title is just the week")
    func planContextNoTitle() {
        let line = ShareCardModel.planContext(
            weekNumber: 2, totalWeeks: 8, planTitle: "  ", isPregnancyPlan: false
        )
        #expect(line == "Week 2 of 8")
    }

    @Test("No plan context off-plan, for impossible weeks, or for a pregnancy plan")
    func planContextAbsent() {
        #expect(ShareCardModel.planContext(weekNumber: nil, totalWeeks: 16, planTitle: "10K", isPregnancyPlan: false) == nil)
        #expect(ShareCardModel.planContext(weekNumber: 0, totalWeeks: 16, planTitle: "10K", isPregnancyPlan: false) == nil)
        #expect(ShareCardModel.planContext(weekNumber: 17, totalWeeks: 16, planTitle: "10K", isPregnancyPlan: false) == nil)
        #expect(ShareCardModel.planContext(weekNumber: 4, totalWeeks: 16, planTitle: "Pregnancy", isPregnancyPlan: true) == nil)
    }

    @Test("Session names read as runs")
    func sessionNames() {
        #expect(ShareCardModel.sessionName(for: .tempo) == "Tempo run")
        #expect(ShareCardModel.sessionName(for: .longRun) == "Long run")
        #expect(ShareCardModel.sessionName(for: .interval) == "Intervals")
    }

    @Test("A run with no plan day has no plan context on its card")
    func unlinkedRunHasNoContext() {
        let run = RunWorkout(date: Date(), distanceMeters: 5_000, durationSeconds: 1_500, workoutType: .easy)
        let model = ShareCardModel.make(from: run, unit: .metric)
        #expect(model.planContext == nil)
        #expect(model.sessionName == "Easy run")
    }
}
