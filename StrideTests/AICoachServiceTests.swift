import Testing
@testable import Stride

struct AICoachServiceTests {

    @Test("Parses structured AI insight JSON from fenced provider response")
    func parsesFencedStructuredResponse() {
        let response = """
        ```json
        {
          "headline": "Control The Finish",
          "summary": "You paced well early but faded late.",
          "action_items": [
            {
              "title": "Start Easier",
              "detail": "Open the first two splits five seconds slower to preserve form.",
              "priority": "High"
            }
          ],
          "next_workout": {
            "title": "35 minute easy run",
            "rationale": "Easy aerobic volume lets you absorb the harder effort."
          }
        }
        ```
        """

        let parsed = AICoachService.parseStructuredResponse(response)

        #expect(parsed?.headline == "Control The Finish")
        #expect(parsed?.actionItems.first?.priority == "High")
        #expect(parsed?.nextWorkout.title == "35 minute easy run")
    }

    @Test("Rejects structured AI insight JSON without action items")
    func rejectsEmptyActionItems() {
        let response = """
        {
          "headline": "Needs Actions",
          "summary": "Valid text is not enough.",
          "action_items": [],
          "next_workout": {
            "title": "Easy run",
            "rationale": "Recover before intensity."
          }
        }
        """

        #expect(AICoachService.parseStructuredResponse(response) == nil)
    }
}
