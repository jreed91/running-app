# Core AI — build context (iOS / iPadOS, Swift)

> **Purpose of this file.** Grounding context for building on-device AI features with Apple’s
> **Core AI** framework (WWDC26). Drop it in the repo (e.g. `docs/coreai-context.md`) and
> reference it from your AI assistant’s instructions (`.github/copilot-instructions.md`,
> `CLAUDE.md`, etc.) so generated code uses the real API surface and the right patterns.
>
> **Provenance & caveat.** Distilled from WWDC26 sessions 324 / 326 / 330. API symbols below
> are taken from Apple’s own session code; anything marked *(pattern)* is an idiom inferred
> from the demos, not a verbatim signature. This is fresh beta-era material — **verify against
> <https://developer.apple.com/documentation/CoreAI> before relying on a symbol.** Session 325
> (“Dive into Core AI model authoring and optimization”) was not yet published when this was
> written.

-----

## 1. Mental model (read this first)

Core AI runs **your own models** fully **on-device** on Apple silicon — **no server, no
per-token cost, no network latency, data stays private.** It is the inference engine behind
on-device Apple Intelligence, now exposed to developers, and is the modern successor to Core ML.

The lifecycle has four stages:

1. **Convert** a model (e.g. PyTorch) to the `.aimodel` format with the `coreai-torch` Python
   package — *or* skip this and pull a ready-made model from the `coreai-models` repo.
1. **Integrate** in Swift: load the `.aimodel`, run inference through a typed Swift API.
1. **Specialize / cache**: Core AI compiles the model for the specific device on first use;
   you manage and pre-warm this.
1. **Deploy**: ship models *outside* the app bundle, download on demand, optionally
   pre-compile ahead-of-time.

The same Swift code runs unchanged across iOS, iPadOS, macOS, and visionOS.

-----

## 2. Decision: Core AI vs. the alternatives — DO NOT default to Core AI

This is the most common mistake. Pick the **highest-level** option that satisfies the feature.

|If the feature is…                                                                                               |Use                                                                                 |Why                                                                              |
|-----------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------|---------------------------------------------------------------------------------|
|General text: summarize, rewrite, classify, extract, simple chat                                                 |**Foundation Models framework** (`LanguageModelSession` on the built-in Apple model)|Built into the OS, zero model to ship, free. No Core AI needed.                  |
|Needs a **specific open-source LLM** (Qwen, Mistral, etc.) or larger/multilingual reasoning than the system model|**Core AI** + `CoreAILanguageModel` → feeds into the same `LanguageModelSession` API|You bring the weights; still get the Foundation Models ergonomics + `@Generable`.|
|Image **segmentation** from a text prompt                                                                        |**Core AI** + `CoreAIImageSegmenter` (e.g. SAM3)                                    |Prebuilt, a few lines.                                                           |
|A **custom / proprietary model** (your own transformer, a niche vision model)                                    |**Core AI** + convert via `coreai-torch`                                            |Full control over `AIModel` / `InferenceFunction`.                               |
|You need to hand-write an **optimized GPU kernel** (custom quantized op, Flash Attention)                        |**Metal TensorOps** (session 330), then plug into Core AI                           |Lowest level; only when profiling proves you need it.                            |
|Legacy `.mlmodel` already shipping and fine                                                                      |**Core ML** (still supported)                                                       |Don’t rewrite working features just to switch frameworks.                        |

**Rule of thumb:** text feature → try Foundation Models first; only reach for Core AI when you
must bring your own weights or run a non-text model.

-----

## 3. Core Swift API surface

Import surfaces seen in the sessions:

```swift
import CoreAI                  // low-level: AIModel, InferenceFunction, NDArray, caching
import CoreAILanguageModels    // CoreAILanguageModel (bring-your-own LLM)
import CoreAIImageSegmenter    // ImageSegmenter (e.g. SAM3)
import FoundationModels        // LanguageModelSession, @Generable — interops with Core AI LMs
```

Low-level types and members observed:

- `AIModel(contentsOf: URL) async throws`
- `AIModel.loadFunction(named: String) throws -> InferenceFunction?`
- `AIModel.specialize(contentsOf: URL) async throws` *(static; explicitly trigger specialization)*
- `InferenceFunction.run(inputs: [String: NDArray]) async throws -> [String: …]`
- `InferenceFunction.run(inputs:states:) async throws` — stateful variant
- `InferenceFunction.MutableViews` — container for stateful buffers; `.insert(&buffer, for: name)`
- `NDArray(shape: [Int], scalarType: .float32)` ; `.mutableView()` ; `.view()`
- `NDArray.MutableView<Float>` , `NDArray.View<Float>`
- `AIModelCache.default` ; `cache.model(for: URL, options: .default)`
- `SpecializationOptions` *(controls how/when specialization runs)*

Outputs come back as a `[String: …]` dictionary keyed by the model’s output names; pull the
`NDArray` out with `outputs.remove("name")?.ndArray`.

-----

## 4. Patterns (copy these shapes)

### 4a. Use a prebuilt LLM — the easiest BYO-model path

```swift
import FoundationModels
import CoreAILanguageModels

@Generable
struct VocabCard {
    let chineseWord: String
    let englishMeaning: String
    let exampleSentence: String
}

let model = try await CoreAILanguageModel(resourcesAt: modelURL)   // e.g. Qwen
let session = LanguageModelSession(model: model)

// Free-form:
let text = try await session.respond(to: "Summarize this note: …")

// Structured / typed output:
let response = try await session.respond(
    to: "Create a vocab card for flower",
    generating: VocabCard.self
)
let card: VocabCard = response.content
```

Key point: a Core AI language model plugs into the **same** `LanguageModelSession` API as the
built-in Apple model — so swapping from the system model to a custom one is mostly a one-line
change, and `@Generable` structured output works either way.

### 4b. Image segmentation

```swift
import CoreAIImageSegmenter

let segmenter = try await ImageSegmenter(resourcesAt: sam3ModelURL)
let response  = try await segmenter.segment(image: inputImage, prompt: "flower")
let mask      = response.segments.first?.mask
```

### 4c. Run a fully custom converted model

```swift
import CoreAI

let model = try await AIModel(contentsOf: modelURL)
let fn    = try model.loadFunction(named: "main")!

var input = NDArray(shape: [sequenceLength, hiddenDim], scalarType: .float32)
writeFeatures(into: input.mutableView())          // your code fills the buffer

var outputs = try await fn.run(inputs: ["features": input])
guard let logits = outputs.remove("logits")?.ndArray else { throw ModelError.missingOutput }
let result = decode(from: logits.view())
```

### 4d. Stateful inference (KV cache) — needed for autoregressive/transformer models

Without a cache, per-step inference cost grows quadratically. Add the KV cache as **model
state** (authored in PyTorch with `register_buffer`, re-converted with `state_names=[…]`), then
pass mutable views each step:

```swift
struct ModelPlayer {
    let fn: InferenceFunction
    var keyCache: NDArray
    var valueCache: NDArray

    init(modelURL: URL) async throws {
        let model = try await AIModel(contentsOf: modelURL)
        self.fn = try model.loadFunction(named: "main")!
        self.keyCache   = NDArray(shape: [layers, maxContext, hiddenDim], scalarType: .float32)
        self.valueCache = NDArray(shape: [layers, maxContext, hiddenDim], scalarType: .float32)
    }

    mutating func step(_ input: NDArray) async throws -> NDArray {
        var states = InferenceFunction.MutableViews()
        states.insert(&keyCache,   for: "keyCache")
        states.insert(&valueCache, for: "valueCache")
        var outputs = try await fn.run(inputs: ["features": input], states: states)
        return outputs.remove("logits")!.ndArray!
    }
}
```

-----

## 5. Performance & first-run experience (the part that bites in production)

**Specialization** = Core AI compiling the model for the exact device. It happens on first use
and can be slow. Design for it explicitly:

- **Detect a cold cache and warn the user** before the first inference:

  ```swift
  let cache = AIModelCache.default
  guard let model = try cache.model(for: modelURL, options: .default) else {
      Task { @MainActor in informUser("Preparing AI features. This may take a while…") }
      // …trigger specialization / show first-run UI…
  }
  ```
- **Pre-compile ahead of time (AOT)** on your dev/build machine to cut on-device first-run cost:

  ```bash
  xcrun coreai-build compile MyModel.aimodel --platform iOS
  ```
- **Don’t bundle large models in the app** — it bloats the download/update for *every* user.
  Ship them via **Background Assets** and download on demand, ideally behind a first-run
  opt-in for the feature.
- **Profile** with the **Core AI Instruments template** to find latency hot-spots (it’s how the
  demos diagnosed the quadratic-attention slowdown that the KV cache fixed).

Recommended deployment shape: first-run experience → opt-in → Background Assets download →
(AOT-compiled assets) → cache check before each session.

-----

## 6. Feature → approach quick map (for ideation)

|Feature idea                                        |Recommended approach                                               |
|----------------------------------------------------|-------------------------------------------------------------------|
|Summarize / rewrite / tag user text                 |Foundation Models (built-in model)                                 |
|On-device chat/assistant with a *specific* model    |Core AI `CoreAILanguageModel` + `LanguageModelSession`             |
|Typed extraction (form fields, structured records)  |`@Generable` + a `LanguageModelSession` (built-in or Core AI model)|
|“Select the object in this photo” / cut-outs        |`CoreAIImageSegmenter` (SAM3)                                      |
|Multilingual generation beyond system model coverage|Core AI + Qwen-style multilingual model                            |
|Custom scoring / prediction model you trained       |Convert with `coreai-torch`, run via `AIModel`/`InferenceFunction` |
|Squeeze more perf from a custom op                  |Metal TensorOps kernel (session 330) wired into Core AI            |

-----

## 7. Rules for the AI assistant generating Core AI code

- Prefer the **Foundation Models** built-in model for plain text features; only introduce Core
  AI when bringing custom weights or running a non-text model.
- Use `async/await` and `try` — the load/run APIs are async and throwing.
- Reference model **inputs/outputs by their declared names** (e.g. `"features"`, `"logits"`);
  never assume positional ordering.
- For any transformer/autoregressive model, **use stateful KV-cache inference**, not repeated
  full-sequence calls.
- Always account for **specialization latency**: check `AIModelCache` and provide first-run UI;
  suggest AOT compilation and Background Assets for shipping.
- Do **not** put model files in the app bundle by default.
- Do **not** invent Core AI symbols. If unsure whether an API exists, say so and point to
  <https://developer.apple.com/documentation/CoreAI> rather than guessing.

-----

## 8. Authoritative references

- Core AI docs — <https://developer.apple.com/documentation/CoreAI>
- Compiling models ahead of time — <https://developer.apple.com/documentation/CoreAI/compiling-core-ai-models-ahead-of-time>
- Managing specialization & caching — <https://developer.apple.com/documentation/CoreAI/managing-model-specialization-and-caching>
- `coreai-torch` (PyTorch → Core AI) — <https://apple.github.io/coreai-torch>
- Core AI optimization — <https://apple.github.io/coreai-optimization>
- Sessions: 324 (Meet Core AI), 326 (Integrate on-device models), 330 (Metal TensorOps)
