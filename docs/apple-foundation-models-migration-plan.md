# Migrating Stride's AI insights to Apple Foundation Models (iOS 27 / WWDC26)

> **Status:** Phase 1 + Phase 2 implemented (merged). **Phase 3 complete** — the app is
> now iOS-27-only and Apple-only: the OpenAI/Anthropic BYO-key providers, the API-key
> storage/UI, and the entire cloud HTTP + JSON-parsing layer have been removed. See
> "Implementation status" and "Phase 3" below.
> **Author context:** Generated from a review of the current AI implementation
> (`AICoachService`, `AIIntegrationService`, `AppSettings`, `AIProvider`) plus the
> WWDC25/WWDC26 Foundation Models sessions and the in-repo `coreai-context.md`.
> **Scope:** Move the four existing "AI insight" features off bring-your-own-key
> cloud LLMs and onto Apple's on-device generative model, with a server-side Apple
> option for the heavy cases.

---

## 0. TL;DR / the one decision that matters

**Use the Foundation Models framework, not Core AI.**

Every AI feature in Stride today is *text in → structured text out*: analyze a run,
chat about training, rewrite a scheduled workout. Apple's own guidance (and the
decision matrix in `docs/coreai-context.md` §2) says: for "summarize / classify /
extract / chat" you use the **Foundation Models framework** on the built-in Apple
model — there is **no model to ship, no per-token cost, and no Core AI involved.**

Core AI is only for *bringing your own weights* (a specific open LLM, a custom
vision/segmentation model, a model you trained yourself). Stride does none of that,
so Core AI, `coreai-torch`, `.aimodel` files, specialization/caching, and Background
Assets downloads are **explicitly out of scope.** They would add a large on-device
download and a first-run compile step for zero benefit over the system model.

The single biggest engineering win is **guided generation with `@Generable`**: it
replaces ~700 lines of hand-rolled, fault-tolerant JSON parsing in `AICoachService`
with compiler-checked Swift types whose structure the model is *guaranteed* to
produce (constrained decoding). That is the headline of this migration, independent
of which model backs it.

---

## 1. What exists today

Stride is a fully native SwiftUI app (deployment target iOS 26, Swift 6 strict
concurrency). "AI insights" are entirely client-side: the user pastes an OpenAI or
Anthropic API key into Settings, and the app makes direct HTTPS calls.

**Four AI features**, all routed through `AICoachService` → `AIIntegrationService`:

| Feature | Entry point | Output type | Streaming |
| --- | --- | --- | --- |
| Post-run coaching insight | `AICoachService.evaluateWithProvider(...)` | `AICoachInsight` (structured) | yes (`onChunk`) |
| Coach chat Q&A | `chatWithProvider(...)` | free text | no |
| Adapt one scheduled workout | `adaptScheduledWorkoutWithProvider(...)` | `AIWorkoutAdaptationResponse` | no |
| Adapt a week's plan | `adaptScheduledWorkoutsWithProvider(...)` | `AIWorkoutPlanAdaptationResponse` | yes (`onChunk`) |

**Key pain points in the current design:**

1. **Fragile JSON handling.** `AICoachService` carries `parseStructuredResponse`,
   `parseWorkoutAdaptationResponse`, `extractFencedJSON`, `extractJSONObject`,
   `parsePartialStructuredResponse`, `extractBalancedObject`, flexible
   string/int/double decoders, and partial-object salvage — all because cloud LLMs
   return prose, code fences, or truncated JSON. Guided generation makes nearly all
   of it dead code.
2. **API-key friction.** No key → `AICoachInsight(headline: "AI Key Required", ...)`.
   The feature is off by default for most users.
3. **Privacy & cost.** Detailed workout data (splits, HR, weather, profile, goals)
   is sent to a third-party endpoint, and the user pays per token.
4. **Prompt-encoded schema.** The JSON schema lives as a giant string literal inside
   `makePrompt` / `makeAdaptationPrompt` / `makePlanAdaptationPrompt`, duplicated
   from the Swift `Codable` structs and kept in sync by hand.

Provider selection is `enum AIProvider { case openAI, anthropic }`
(`Stride/Core/Models/Enums.swift:246`), with `defaultModel` / `displayName`.
Settings store `aiProvider`, `aiAPIKey` (local-only, never iCloud-synced),
`aiModelOverride`, and `aiInsightsEnabled`.

---

## 2. WWDC grounding (what the API actually gives us)

Verified against the official Apple session pages.

### Foundation Models framework — WWDC25 (iOS 26, available today)
Sessions: 286 *Meet the Foundation Models framework*, 301 *Deep dive*, 259 *Code-along*.

- `SystemLanguageModel.default` — the on-device Apple Intelligence LLM. Check
  `.availability` (`.available` / `.unavailable(reason)` where reason is
  `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady`).
- `LanguageModelSession` — stateful session created with `instructions:` and
  optional `tools:`. Keeps a transcript across turns (maps directly to our chat).
- `session.respond(to:)` for free text; `session.respond(to:generating: SomeType.self)`
  for structured output; `session.streamResponse(...)` for token streaming.
- `@Generable` macro + `@Guide` — annotate a Swift type and its fields; the framework
  uses **constrained decoding** to *guarantee* the model emits that exact structure.
  This is the replacement for our prompt-encoded JSON schema + parsers.
- Tool calling: a `Tool` protocol lets the model call back into app code.
- Guardrails: a default safety guardrail is always on (relevant to our coaching/health
  wording — see Risks §8).

> **Important:** the base framework is available on **iOS 26** already. Stride's
> deployment target is 26.0, so **Phase 1 below ships without bumping to iOS 27.**

### What's new at WWDC26 (iOS 27) — session 241
These are the iOS-27-specific upgrades worth adopting in Phase 2:

- **`LanguageModel` protocol** — a provider abstraction. `LanguageModelSession` can be
  backed by *any* conforming model. The system model conforms; new conformers include
  `CoreAILanguageModel`, `MLXLanguageModel`, and `PrivateCloudComputeLanguageModel`.
- **`PrivateCloudComputeLanguageModel`** — Apple's server model over Private Cloud
  Compute: ~32K context, a `reasoningLevel` (`.light` / `.deep`), **no API key / no
  account / no billing**, same privacy posture. Ideal for our heaviest case (weekly
  plan adaptation with many workouts).
- **`ContextOptions(reasoningLevel:)`** on `respond(...)`, plus `response.usage`
  (input/output/cached/reasoning token counts) for inspection.
- **Partner Swift packages**: Anthropic and Google publish SPM packages whose models
  conform to `LanguageModel`, with auth/billing via OAuth + Keychain. This means our
  bespoke OpenAI/Anthropic `URLSession` code in `AIIntegrationService` could be
  **deleted** in favor of a partner package behind the same `LanguageModelSession` API.
- **`model.contextSize` / `model.tokenCount(for:)`** (iOS 26.4+) — pre-flight prompt
  sizing, useful for the plan-adaptation prompt which can get large.
- **Vision input** (`Attachment(UIImage(...))`) and system tools (`OCRTool`,
  `BarcodeReaderTool`, Spotlight RAG) — not needed for current features; noted as
  future options in §7.

Sources are listed in §10.

---

## 3. Target architecture

Keep the public surface of `AICoachService` and the `AIIntegrationServiceProtocol`
seam intact (so views, `AppContainer`, and tests barely move). Add Apple's model as a
new backend behind that seam.

```text
View (RunSummaryView, AICoachChatView, PlanTabView)
  -> AICoachService            (unchanged public methods)
       -> CoachInsightBackend  (new protocol: cloud vs. on-device)
            ├── CloudCoachBackend          (wraps today's AIIntegrationService)
            └── FoundationModelsCoachBackend (NEW: LanguageModelSession + @Generable)
```

### 3.1 Provider enum
Add an on-device case and (Phase 2) an Apple-server case:

```swift
enum AIProvider: String, CaseIterable, Sendable {
    case appleOnDevice = "apple_on_device"   // NEW — default
    case applePrivateCloud = "apple_pcc"     // NEW — Phase 2, iOS 27
    case openAI = "openai"
    case anthropic = "anthropic"

    var requiresAPIKey: Bool { self == .openAI || self == .anthropic }
    var isAppleModel: Bool { self == .appleOnDevice || self == .applePrivateCloud }
}
```

### 3.2 `@Generable` output types
This is the core of the work. Re-express each existing `Codable` output as a
`@Generable` type and let guided generation enforce the shape. The current
`Codable` structs can stay (for the cloud path / persistence cache), or we map
the `@Generable` value into them. Example for the post-run insight:

```swift
import FoundationModels

@Generable
struct GeneratedCoachInsight {
    @Guide(description: "Short coaching headline, at most 8 words")
    let headline: String

    @Guide(description: "One plain-language sentence with the main takeaway")
    let summary: String

    @Guide(description: "3–5 sentence coaching explanation: the why, the evidence, the adjustment")
    let fullAnalysis: String

    @Guide(description: "Confidence from 0 to 100", .range(0...100))
    let confidence: Int

    @Guide(description: "Exactly 4 compact evidence chips", .count(4))
    let evidence: [GeneratedEvidence]

    @Guide(description: "Exactly 3 prioritised action items", .count(3))
    let actionItems: [GeneratedActionItem]

    let nextWorkout: GeneratedNextWorkout
}

@Generable
struct GeneratedEvidence {
    @Guide(description: "Metric label, ≤10 characters") let label: String
    @Guide(description: "Metric value, ≤12 characters") let value: String
    let delta: String?
    @Guide(description: "One of: warning, success, brand, easy, interval, neutral")
    let tone: CoachTone   // a @Generable enum gives the model a closed set
}
```

> Notes:
> - `@Guide` constraints like `.range`, `.count`, and enum types replace the long
>   prose rules in `makePrompt`. The framework enforces count/range structurally, so
>   the `.prefix(4)` / `min(max(...))` clamps in `evaluateWithProvider` become
>   belt-and-braces rather than load-bearing.
> - Modelling `tone`/`priority`/`workout_type` as **`@Generable` enums** eliminates a
>   whole class of "the model returned an unexpected string" bugs and removes
>   `workoutType(from:)` string matching.
> - Do the same for `AIWorkoutAdaptationResponse` (→ `GeneratedWorkoutAdaptation`,
>   `workoutType` as enum) and `AIWorkoutPlanAdaptationResponse`
>   (→ `GeneratedPlanAdaptation` with an array of per-workout adaptations carrying
>   the `workoutID` string). Validation in `isValidAdaptation` /
>   `isValidStructure` stays — never trust *semantics* from any model, even a
>   guaranteed-shape one.

### 3.3 The on-device backend

```swift
@MainActor
final class FoundationModelsCoachBackend {
    func makeInsight(prompt: String, instructions: String,
                     onChunk: @escaping @Sendable (String) -> Void) async throws -> GeneratedCoachInsight {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw CoachBackendError.modelUnavailable }

        let session = LanguageModelSession(instructions: instructions)
        // Streaming partials drive the existing onChunk UI:
        let stream = session.streamResponse(to: prompt, generating: GeneratedCoachInsight.self)
        var last: GeneratedCoachInsight.PartiallyGenerated?
        for try await partial in stream {
            last = partial
            onChunk(partial.summary ?? "")     // feed whatever the UI shows live
        }
        return try last?.complete() ?? { throw CoachBackendError.empty }()
    }
}
```

> `streamResponse(generating:)` yields a `PartiallyGenerated` snapshot (all fields
> optional) as the structure fills in. This is a *better* fit for our `onChunk`
> progress UI than concatenating raw token text, and it removes the need to parse
> partial JSON (`parsePartialStructuredResponse` and friends can be deleted on the
> on-device path).

### 3.4 Reusing existing prompt construction
**Do not rewrite the prompt builders.** `makePromptContext`, `makeWorkoutDetails`,
`makeAdaptationContext`, `makePlanAdaptationContext` are model-agnostic, valuable
domain logic (pace drift, HR drift, weather/elevation framing, recent-history
formatting). They keep producing the *content*; only the *transport + schema
enforcement* changes. The big JSON-schema string literals inside `makePrompt`
etc. are replaced by `@Guide` annotations and short natural-language instructions.

---

## 4. Phasing

### Phase 0 — Spike & feasibility (0.5–1 day)
- Confirm Foundation Models availability on the target test device (Apple
  Intelligence requires eligible hardware — A17 Pro / M-series — and the toggle on).
- Build a throwaway harness that runs `GeneratedCoachInsight` against one real run's
  prompt and eyeballs quality vs. the current `gpt-4o-mini` output.
- Decide quality bar for the on-device model vs. cloud (see Risks §8).

### Phase 1 — On-device insights (iOS 26, no deployment-target change)
1. Add `@Generable` types (§3.2) mirroring `AICoachInsight`, `AIWorkoutAdaptationResponse`,
   `AIWorkoutPlanAdaptationResponse`, and mappers to the existing `Codable` structs.
2. Introduce the `CoachInsightBackend` protocol; wrap current
   `AIIntegrationService` as `CloudCoachBackend`; add `FoundationModelsCoachBackend`.
3. Add `AIProvider.appleOnDevice`; make it the **default**.
4. In `AICoachService`, branch on `provider.isAppleModel` to use the on-device
   backend (no key, `@Generable`, streaming partials) vs. the cloud backend.
5. Implement chat as a persistent `LanguageModelSession(instructions:)` reusing the
   coach system prompt already in `requestOpenAIChat`/`requestAnthropicChat`.
6. Availability + fallback logic (§5).
7. Settings UX (§6).
8. Tests (§9).

### Phase 2 — iOS 27 upgrades (bump deployment target to 27.0, or gate with `if #available`)
1. Adopt the **`LanguageModel` protocol** abstraction so all backends share one
   `LanguageModelSession` code path.
2. Add `AIProvider.applePrivateCloud` backed by `PrivateCloudComputeLanguageModel`
   for the **weekly plan adaptation** (largest prompt, benefits from 32K context +
   `reasoningLevel: .deep`). Keep on-device for the per-run insight and chat.
3. Use `model.tokenCount(for:)` to pre-flight the plan-adaptation prompt and pick
   on-device vs. PCC automatically.
4. **Optional:** replace bespoke OpenAI/Anthropic HTTP in `AIIntegrationService` with
   the official partner SPM packages (they conform to `LanguageModel`), deleting the
   request/response/stream-decoding structs at the bottom of `AIIntegrationService.swift`.
5. Surface `response.usage` in Pulse diagnostics instead of raw HTTP bodies.

### Phase 3 — Cleanup (DONE — Apple-only, iOS 27)
Cloud BYO-key was dropped entirely. Concretely:
- `AIProvider` now has only `.appleOnDevice` and `.applePrivateCloud`; `requiresAPIKey`,
  `isAppleModel`, and `defaultModel` are gone (all providers are keyless Apple models).
- `AppSettings` no longer stores `aiAPIKey` / `aiModelOverride`; `hasAICredentials` is
  always `true` (Apple models need no key).
- `AICoachService` is on-device-only: the cloud branches, `apiKey`/`modelOverride`
  parameters, the `AIIntegrationServiceProtocol` dependency, and the ~200 lines of
  fault-tolerant JSON parsing (`parseStructuredResponse`, `parseWorkout*Response`,
  `extractFencedJSON`, `extractBalancedObject`, partial-object salvage, …) were deleted.
- `AIIntegrationService.swift` (OpenAI/Anthropic `URLSession` code + request/response
  structs) was deleted; `AIProviderChatMessage` moved into `AICoachService.swift`.
- Deployment target raised to **iOS 27.0**. Private Cloud Compute is now the **default**
  provider and the path is compiled in unconditionally — see "Phase 2: Private Cloud
  Compute is live" below for the state that supersedes the flag history here.
  `STRIDE_ENABLE_IOS27_MODELS` was briefly defined in `project.yml` when the path was
  written against *guessed* WWDC26 symbol names, and Xcode Cloud failed with "Cannot find
  'PrivateCloudComputeLanguageModel' in scope"; the flag was removed and the path stayed
  compiled out. The symbols have since been confirmed against Apple's published
  documentation (`PrivateCloudComputeLanguageModel`, iOS 27.0+), so the flag is gone for
  good and the gate is `availability` at runtime instead of a compile-time `#if`.
  - **Availability gate (crash fix).** Running inference on
    `PrivateCloudComputeLanguageModel` without the Private Cloud Compute entitlement
    traps inside `Executor.assertEntitled()` — a fatal `EXC_BREAKPOINT`, not a
    catchable Swift error, so the `do/catch` around inference can't recover (observed
    on TestFlight build 135 when a user selected "Apple Private Cloud Compute").
    **This gate must survive every refactor of `FoundationModelsCoachBackend`.**
    `withServerFallback` checks `model.availability == .available` *before* creating the
    session, and falls back to the on-device model otherwise. `availability` reflects the
    entitlement, device eligibility, and whether Apple Intelligence is enabled, so this is
    fail-safe: it only routes to on-device, never crashes.
  - **Enabling PCC (entitlement).** PCC is a *restricted* entitlement Apple grants per
    developer account: request it at
    `https://developer.apple.com/contact/request/private-cloud-compute/` (requires
    enrollment in the App Store Small Business Program and fewer than 2M first-time
    downloads). Once the account/App ID is granted access, add the Private Cloud
    Compute capability so the entitlement lands in `Stride.entitlements` /
    `project.yml`; `isAvailable` then returns `true` and coaching routes to PCC.
    Until the grant is in the provisioning profile, the app safely uses the on-device
    model.

### Phase 2: Private Cloud Compute is live

Verified against Apple's published docs, [Adding server-side intelligence with Private
Cloud Compute](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute):

| Symbol | Shape |
| --- | --- |
| `PrivateCloudComputeLanguageModel` | `final class`, iOS 27.0+, conforms to `LanguageModel` |
| `init()` | convenience, no arguments |
| `availability` | `.available` / `.unavailable(.deviceNotEligible)` / `.unavailable(.systemNotReady)` |
| `quotaUsage` | `.status` → `.belowLimit(info)` (`info.isApproachingLimit`) / `.limitReached`; plus `isLimitReached`, `resetDate`, `limitIncreaseSuggestion?.show()` |
| `contextSize` | **`nonisolated(nonsending) var { get async throws }`** — not a plain property. Needs `try await` *and* an isolated caller, or the compiler rejects it with "Caller isolation inheriting-isolated property 'contextSize' cannot be accessed from outside of the actor". `ServerModelStatus` deliberately omits it |
| `Error` | `.quotaLimitReached` / `.networkFailure` / `.serviceUnavailable` — **catchable**, and non-frozen, so switch with `@unknown default` |
| `ContextOptions` | `init(includeSchemaInPrompt: Bool? = nil, reasoningLevel: ReasoningLevel? = nil)`; levels `.light` / `.moderate` / `.deep` |

What landed:

- `com.apple.developer.private-cloud-compute: true` in `project.yml` (Boolean; a **managed**
  entitlement Apple assigns per account — it cannot be self-served in the portal).
- `AppSettings` defaults new installs to `.applePrivateCloud`. A stored choice always wins,
  so a runner who picked on-device keeps it.
- `withServerFallback` is the single branch point: gate on `availability`, retry on-device
  for `.networkFailure` / `.serviceUnavailable` (Apple's documented guidance), and convert
  `.quotaLimitReached` into `OnDeviceCoachError.serverQuotaExceeded(resetDate:)`.
- Reasoning per task, server path only: `.light` chat, `.moderate` insight and single-workout
  adaptation, `.deep` whole-plan adaptation. With the `contextOptions` overload keep
  `includeSchemaInPrompt: true` — that overload drops the standalone argument and defaults
  it to `true`, so omitting it silently loses the guided-generation schema bias.
- Quota is surfaced, not swallowed: `ServerModelStatus` (a plain value type, so
  `AICoachService` and the views still never import `FoundationModels`) drives a
  **Settings → AI Coach** status row with the `limitIncreaseSuggestion` upgrade button, and
  `AICoachChatView` names the real cause instead of blaming Apple Intelligence setup.

Still open:

- Token-level streaming still emits a single partial; `streamResponse(to:generating:)` is
  unverified on-device.
- `model.tokenCount(for:)` pre-flight trimming (see the risk table) is not implemented — PCC's
  32K window makes it much less pressing for the plan-adaptation prompt.

- Settings drops the API-key `SecureField` and model-override field; `SettingsView`,
  `RunSummaryView`, `AICoachChatView`, and `PlanTabView` copy no longer mentions keys.
- Tests: `AICoachServiceTests.swift` (cloud JSON-parse tests) removed;
  `FoundationModelsCoachServiceTests.swift` updated to the keyless API.

> **App Intents / Siri / Apple Intelligence:** Following Apple's *Apple Intelligence and
> Siri* App Intents guidance (entities are the foundation, indexed in Spotlight for
> semantic discovery):
> - `StrideShortcuts` (an `AppShortcutsProvider`) exposes `TodaysRunIntent` and
>   `WeeklySummaryIntent` — headless, read-only intents Siri runs by voice without opening
>   the app. Auto-discovered at launch; phrases broadened for recognition.
> - `RunWorkoutEntity` models a completed run as an `AppEntity` and conforms to
>   `IndexedEntity`, so runs are indexed in Spotlight and can be found/referenced by
>   Apple Intelligence and passed into intents. `RunWorkoutEntityQuery`
>   (`EntityQuery` + `EntityStringQuery`) resolves runs by id, suggestion, and text.
> - `RunDetailsIntent(run:)` is an entity-driven action available in Shortcuts / Siri.
> - `RunSpotlightIndexer` indexes recent runs at launch via `CSSearchableIndex`.
>
> Note: Apple's *assistant schema domains* (`@AssistantIntent` / `@AssistantEntity`)
> cover Messages, Calendar, Audio, Clock, Photos, etc. — there is no fitness/running
> domain, so schema adoption does not apply to Stride's core actions. The entity +
> Spotlight-index + App Shortcuts path above is the recommended integration for a
> running app.

---

## 5. Availability & graceful fallback

Foundation Models is **not guaranteed present** (ineligible device, Apple
Intelligence off, model still downloading). Fallback ladder when the selected
provider is `appleOnDevice`:

1. `SystemLanguageModel.default.availability == .available` → use it.
2. Else, if a cloud API key is configured → fall back to cloud.
3. Else → return a **local heuristic insight**. We already compute real analysis in
   `makePromptContext` (pace drift %, HR drift, weather/elevation, baseline delta) —
   surface that as a non-AI `AICoachInsight` instead of today's "AI Key Required"
   dead-end. This makes the feature *always* show something useful.

Map `.unavailable` reasons to clear copy:
- `.deviceNotEligible` → "On-device coaching needs a newer iPhone; using local analysis."
- `.appleIntelligenceEnabled` off → "Turn on Apple Intelligence in Settings to enable on-device coaching."
- `.modelNotReady` → "Preparing on-device intelligence… try again shortly."

---

## 6. Settings / UX changes

- Default `aiProvider` to `.appleOnDevice`; existing users with a key keep their
  choice.
- Provider picker shows "On-device (Apple Intelligence)" first, then "Apple Private
  Cloud" (Phase 2), then OpenAI / Claude (BYO key).
- Hide the API-key `SecureField` and model-override field unless a BYO-key provider
  is selected (`provider.requiresAPIKey`).
- Add a one-line privacy note for Apple providers: "Runs on your device. Your
  training data never leaves your iPhone." (On-device); PCC gets Apple's standard
  PCC privacy language.
- `aiInsightsEnabled` can now default **on** for eligible devices, since there's no
  key/cost barrier.

---

## 7. Out of scope now, possible later (genuinely Apple-AI-shaped)

- **Tool calling** — expose a `Tool` that lets the chat session query the user's
  actual run history / training plan on demand (local RAG) instead of stuffing
  context into every prompt. Reduces prompt size and improves grounding.
- **Vision** (iOS 27 multimodal) — analyze a shared route/elevation screenshot, or a
  photo of a treadmill display, via `Attachment(UIImage(...))`. New feature, not a
  migration.
- **Core AI** — only if Stride ever ships a *custom-trained* model (e.g. a proprietary
  race-time/injury-risk predictor converted with `coreai-torch`, or a multilingual
  coach via a specific open LLM). Until then, do not introduce it.

---

## 8. Risks & mitigations

| Risk | Mitigation |
| --- | --- |
| On-device model is smaller than `gpt-4o-mini`/Claude; coaching nuance may drop | Phase 0 quality spike; keep cloud BYO-key as an opt-in "power" tier; route the hardest case (plan adaptation) to PCC in Phase 2 |
| Context window: weekly plan-adaptation prompt with many workouts + 8-run history may exceed on-device limits | Pre-flight with `model.tokenCount(for:)`; trim history; use `PrivateCloudComputeLanguageModel` (32K) for that path |
| Guardrails false-positives on health/coaching language | WWDC26 notes refined guardrails (fewer false positives) on 26.4+; keep wording non-clinical (existing prompts already avoid medical claims); have the local-heuristic fallback ready if a response is blocked |
| Availability on simulator/CI | Gate FM tests behind availability; keep deterministic unit tests on the mapping/validation layer, not the model |
| Strict concurrency (Swift 6) | `LanguageModelSession` work is `@MainActor`-friendly; mirror existing `@MainActor` annotations on `AICoachService` methods |
| iOS 27 APIs unavailable to iOS 26 users | Phase 1 is iOS-26-safe; gate Phase 2 PCC/`LanguageModel`-protocol code with `if #available(iOS 27, *)` or bump the target |

---

## 9. Testing

- **Keep** `AICoachServiceTests` JSON-parsing tests while the cloud path exists; they
  validate `CloudCoachBackend`.
- **Add** mapping tests: `GeneratedCoachInsight` → `AICoachInsight`, enum tone/priority
  round-trips, and that `isValidAdaptation` / `isValidStructure` still gate semantics.
- **Add** availability-branch tests with a stubbed backend conforming to
  `CoachInsightBackend`, covering: model available, unavailable→cloud, unavailable+no
  key→local heuristic.
- **Manual/device**: run on an Apple-Intelligence-eligible device; verify streaming
  partials drive the `RunSummaryView` progress UI; verify chat transcript continuity.
- Foundation Models needs an eligible device + Apple Intelligence on; do **not** rely
  on it in simulator CI — abstract behind `CoachInsightBackend` so logic tests use a
  fake.

---

## 10. File-level change list (Phase 1)

| File | Change |
| --- | --- |
| `Stride/Core/Models/Enums.swift` | Add `.appleOnDevice` (+ `.applePrivateCloud` later) to `AIProvider`; add `requiresAPIKey` / `isAppleModel` |
| `Stride/Core/Services/FoundationModelsCoachBackend.swift` *(new)* | `LanguageModelSession` + `@Generable` types + streaming partials |
| `Stride/Core/Services/CoachInsightBackend.swift` *(new)* | Protocol seam; `CloudCoachBackend` wrapping current `AIIntegrationService` |
| `Stride/Core/Services/AICoachService.swift` | Branch on `provider.isAppleModel`; on-device path bypasses JSON parsing; local-heuristic fallback insight |
| `Stride/Core/Models/AppSettings.swift` | Default provider `.appleOnDevice`; key/model only meaningful for BYO providers |
| `Stride/Features/Settings/SettingsView.swift` | Reorder picker; gate key/model fields on `requiresAPIKey`; privacy copy |
| `Stride/Features/History/RunSummaryView.swift` | Use streaming partials; drop "AI Key Required" dead-end for Apple providers |
| `StrideTests/AICoachServiceTests.swift` | Add mapping + availability-branch tests; keep existing cloud-parse tests |
| `project.yml` | No SPM needed for Foundation Models (system framework). Phase 2 only: deployment target → 27.0 and/or partner SPM packages |

No `project.yml` package additions, `.aimodel` assets, Background Assets, or Core AI
entitlements are required for this migration.

---

## 11. Implementation status (this branch)

Phases 1 and 2 are implemented. **Not yet built/verified** — this repo builds on macOS
with Xcode (per `AGENTS.md`); it was authored in a Linux container with no iOS SDK, so a
build + on-device test pass on an Apple-Intelligence-eligible device is still required.

**Added**
- `AIProvider.appleOnDevice` / `.applePrivateCloud` + `requiresAPIKey` / `isAppleModel` /
  `usesPrivateCloudCompute` (`Enums.swift`).
- `Stride/Core/Services/FoundationModels/`
  - `OnDeviceCoachGenerating.swift` — backend protocol + `OnDeviceCoachFactory` (no FM import).
  - `FoundationModelsCoachTypes.swift` — `@Generable` types + mappers to existing structs.
  - `FoundationModelsCoachBackend.swift` — `LanguageModelSession` backend for both models;
    the PCC path is compiled in and gated at runtime by `withServerFallback`.
- `AppSettings.hasAICredentials` / `isAICoachReady`; default provider now `.applePrivateCloud`.
- `AICoachService` branches Apple providers to the on-device backend (producing the existing
  structured types), with a local-heuristic fallback; on-device instruction/prompt builders.
- `StrideTests/FoundationModelsCoachServiceTests.swift` — provider flags, availability
  branch (uses/falls-back), cloud-still-needs-key, and `@Generable` mapping tests.

**Changed (UI gating)** — `SettingsView` (hide key/model fields for keyless providers,
provider-aware footnote), `RunSummaryView` / `AICoachChatView` / `PlanTabView` now gate on
`hasAICredentials` instead of a raw key check.

**Deployment target** iOS 27.0 on every target, so the iOS 27 symbols
(`PrivateCloudComputeLanguageModel`, `ContextOptions`) need no `#if` and no `#available`.

### Verify-against-SDK checklist (beta-era symbols)
- [ ] `SystemLanguageModel.default.availability` cases (`deviceNotEligible`,
      `appleIntelligenceNotEnabled`, `modelNotReady`).
- [ ] `LanguageModelSession(model:instructions:)` accepting a `String` instructions value.
- [ ] `session.respond(to:generating:)` → `.content`, and `respond(to:)` → `.content`.
- [ ] `@Generable` / `@Guide(.range/.count)` and `@Generable` enums.
- [x] `PrivateCloudComputeLanguageModel` — verified against Apple's docs; see the symbol
      table in "Phase 2: Private Cloud Compute is live". Note the reasoning level lives on
      `ContextOptions(reasoningLevel:)`, **not** `GenerationOptions`, and the PCC error enum
      is catchable (`.quotaLimitReached` / `.networkFailure` / `.serviceUnavailable`).
- [ ] Confirm the `@Generable` macro preserves the memberwise initializer (used by the
      mapping tests); adjust the tests if it generates a different init.

---

## 12. Authoritative references

- Foundation Models framework — https://developer.apple.com/documentation/FoundationModels
- WWDC25 286 *Meet the Foundation Models framework* — https://developer.apple.com/videos/play/wwdc2025/286/
- WWDC25 301 *Deep dive into the Foundation Models framework* — https://developer.apple.com/videos/play/wwdc2025/301/
- WWDC25 259 *Code-along: Bring on-device AI to your app* — https://developer.apple.com/videos/play/wwdc2025/259/
- WWDC26 241 *What's new in the Foundation Models framework* — https://developer.apple.com/videos/play/wwdc2026/241/
- In-repo Core AI grounding (why Core AI is *not* used here) — `docs/coreai-context.md` §2
