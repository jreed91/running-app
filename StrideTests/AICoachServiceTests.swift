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
          "full_analysis": "You controlled the opening kilometers well, then the final split drifted as heart rate climbed. Treat this as a sign to protect the first half of similar runs and keep the effort ceiling lower. Next week, open slightly easier and let the final kilometer be the controlled progression.",
          "confidence": 84,
          "evidence": [
            { "label": "Pace", "value": "5:42/km", "delta": "late fade", "tone": "warning" },
            { "label": "HR avg", "value": "154 bpm", "delta": "+8", "tone": "warning" },
            { "label": "Split 5", "value": "6:02", "delta": "slow", "tone": "neutral" },
            { "label": "Load", "value": "high", "delta": null, "tone": "brand" }
          ],
          "action_items": [
            {
              "title": "Start Easier",
              "detail": "Open the first two splits five seconds slower to preserve form.",
              "priority": "High",
              "metric": "-5 sec",
              "tone": "warning"
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
        #expect(parsed?.fullAnalysis?.contains("heart rate climbed") == true)
        #expect(parsed?.confidence == 84)
        #expect(parsed?.evidence.count == 4)
        #expect(parsed?.actionItems.first?.priority == "High")
        #expect(parsed?.actionItems.first?.metric == "-5 sec")
        #expect(parsed?.nextWorkout.title == "35 minute easy run")
    }

    @Test("Rejects structured AI insight JSON without action items")
    func rejectsEmptyActionItems() {
        let response = """
        {
          "headline": "Needs Actions",
          "summary": "Valid text is not enough.",
          "confidence": 70,
          "evidence": [
            { "label": "Pace", "value": "5:42/km", "delta": null, "tone": "neutral" }
          ],
          "action_items": [],
          "next_workout": {
            "title": "Easy run",
            "rationale": "Recover before intensity."
          }
        }
        """

        #expect(AICoachService.parseStructuredResponse(response) == nil)
    }

    @Test("Parses structured AI workout adaptation JSON")
    func parsesWorkoutAdaptationResponse() throws {
        let response = """
        {
          "workout_type": "Interval",
          "target_distance_meters": 5200,
          "target_pace_lower_bound": 295,
          "target_pace_upper_bound": 305,
          "explanation": "Reduced the repeat count slightly because recent quality sessions faded late.",
          "intervals": [
            {
              "repetitions": 4,
              "distance_meters": 800,
              "duration_seconds": null,
              "target_pace_seconds_per_km": 300,
              "recovery_seconds": 90,
              "recovery_type": "jog"
            }
          ],
          "workout_structure": {
            "warmup": {
              "distance_meters": 1000,
              "duration_seconds": null,
              "target_pace_seconds_per_km": 390,
              "label": "Warm-up"
            },
            "main_sets": [
              {
                "repetitions": 4,
                "work_segment": {
                  "distance_meters": 800,
                  "duration_seconds": null,
                  "target_pace_seconds_per_km": 300,
                  "label": "Interval"
                },
                "recovery_segment": {
                  "distance_meters": null,
                  "duration_seconds": 90,
                  "target_pace_seconds_per_km": null,
                  "label": "Recovery jog"
                },
                "label": "Controlled intervals"
              }
            ],
            "cooldown": {
              "distance_meters": 1000,
              "duration_seconds": null,
              "target_pace_seconds_per_km": 390,
              "label": "Cool-down"
            },
            "total_estimated_distance_meters": 5200,
            "total_estimated_duration_seconds": 1900
          }
        }
        """

        let parsed = try #require(AICoachService.parseWorkoutAdaptationResponse(response))

        #expect(parsed.workoutType == "Interval")
        #expect(parsed.intervals.first?.repetitions == 4)
        #expect(parsed.workoutStructure?.mainSets.first?.label == "Controlled intervals")
    }

    @Test("Parses batched workout adaptation JSON")
    func parsesWorkoutPlanAdaptationResponse() throws {
        let workoutID = "11111111-1111-1111-1111-111111111111"
        let response = """
        {
          "adaptations": [
            {
              "workout_id": "\(workoutID)",
              "workout_type": "Tempo",
              "target_distance_meters": 6000,
              "target_pace_lower_bound": 320,
              "target_pace_upper_bound": 335,
              "explanation": "Kept this as tempo but trimmed the work block because recent runs show late fatigue.",
              "intervals": [],
              "workout_structure": {
                "warmup": {
                  "distance_meters": 1000,
                  "duration_seconds": null,
                  "target_pace_seconds_per_km": 390,
                  "label": "Warm-up"
                },
                "main_sets": [
                  {
                    "repetitions": 1,
                    "work_segment": {
                      "distance_meters": 4000,
                      "duration_seconds": null,
                      "target_pace_seconds_per_km": 328,
                      "label": "Tempo"
                    },
                    "recovery_segment": {
                      "distance_meters": null,
                      "duration_seconds": null,
                      "target_pace_seconds_per_km": null,
                      "label": ""
                    },
                    "label": "Tempo Block"
                  }
                ],
                "cooldown": {
                  "distance_meters": 1000,
                  "duration_seconds": null,
                  "target_pace_seconds_per_km": 390,
                  "label": "Cool-down"
                },
                "total_estimated_distance_meters": 6000,
                "total_estimated_duration_seconds": 2100
              }
            }
          ]
        }
        """

        let parsed = try #require(AICoachService.parseWorkoutPlanAdaptationResponse(response))

        #expect(parsed.adaptations.first?.workoutID == workoutID)
        #expect(parsed.adaptations.first?.workoutType == "Tempo")
        #expect(parsed.adaptations.first?.workoutStructure?.totalEstimatedDistanceMeters == 6000)
    }

    @Test("Rejects workout adaptation without explanation")
    func rejectsWorkoutAdaptationWithoutExplanation() {
        let response = """
        {
          "workout_type": "Easy",
          "target_distance_meters": 5000,
          "target_pace_lower_bound": 360,
          "target_pace_upper_bound": 390,
          "explanation": "",
          "intervals": [],
          "workout_structure": {
            "warmup": {
              "distance_meters": 1000,
              "duration_seconds": null,
              "target_pace_seconds_per_km": 390,
              "label": "Warm-up"
            },
            "main_sets": [
              {
                "repetitions": 1,
                "work_segment": {
                  "distance_meters": 3000,
                  "duration_seconds": null,
                  "target_pace_seconds_per_km": 375,
                  "label": "Easy"
                },
                "recovery_segment": {
                  "distance_meters": null,
                  "duration_seconds": null,
                  "target_pace_seconds_per_km": null,
                  "label": ""
                },
                "label": "Easy Block"
              }
            ],
            "cooldown": {
              "distance_meters": 1000,
              "duration_seconds": null,
              "target_pace_seconds_per_km": 390,
              "label": "Cool-down"
            },
            "total_estimated_distance_meters": 5000,
            "total_estimated_duration_seconds": 1900
          }
        }
        """

        #expect(AICoachService.parseWorkoutAdaptationResponse(response) == nil)
    }
}
