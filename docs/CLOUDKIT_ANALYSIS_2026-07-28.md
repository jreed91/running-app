# CloudKit Setup Analysis — 2026-07-28

A line-by-line audit of Stride's CloudKit configuration against Apple's published
requirements. Every claim below is anchored to a numbered source in
[§7 Sources](#7-sources); `[S1]`-style markers point at the exact document.

Scope: the SwiftData ↔ CloudKit mirroring stack — `project.yml` capabilities,
`AppContainer`'s store setup, the eight `@Model` types, the App Intents store,
the restore flow, and `docs/CLOUDKIT_VALIDATION.md`. It does **not** cover iCloud
key-value storage beyond noting where it interacts with the sync toggle.

**Status: all six findings are fixed** — see the ✅ notes in §3. The audit is kept in full
rather than trimmed to a changelog, because the reasoning is what stops F1 being
reintroduced by the next `ModelConfiguration` that omits an argument.

The fixes change how the app opens its persistent store, and `AGENTS.md` requires that be
validated on a physical device. **That validation has not been run** — §6 is the device
checklist, not a build order.

---

## 1. Verdict

The **schema** is textbook-correct: all eight models satisfy every CloudKit
constraint Apple documents, and the two places where CloudKit cannot enforce a
guarantee (uniqueness, relationship ordering) already have hand-written
mitigations. That part of the setup is better than most.

The **store configuration** had one defect that undid several of the app's stated
behaviours, and one missing operational step that could make sync fail silently in the
App Store build only. Both are fixed; §5 records what each fix was and what it has to
keep true.

| Area | Status |
| --- | --- |
| Capabilities & entitlements | ✅ Conformant |
| CloudKit-compatible schema (all 8 models) | ✅ Conformant |
| Explicit container selection for the sync path | ✅ Conformant |
| Uniqueness / relationship-ordering mitigations | ✅ Conformant |
| Non-sync store configurations | ✅ **F1 FIXED** — every config now names `cloudKitDatabase` |
| Development-schema initialisation & production deploy | ✅ **F2 FIXED** — initializer added, release gate documented |
| `SavedRoute` 1 MB blob risk | ✅ **F3 FIXED** — comment corrected |
| Test coverage of the sync decision | ✅ **F4 FIXED** — `CloudKitConfigurationTests` |
| Simulator carve-out | ✅ **F5 FIXED** — kept, now effective, reason documented |
| CloudKit state on the debug screen | ✅ **F6 FIXED** — status + recent events |

---

## 2. What is correct

### 2.1 Capabilities and entitlements

Apple requires exactly two capabilities: *"SwiftData requires two separate
capabilities to perform automatic iCloud sync: the iCloud capability, which lets
you configure CloudKit, and the Background Modes capability, which lets your app
receive remote notifications from CloudKit"* `[S1]`.

| Requirement | Where | Status |
| --- | --- | --- |
| iCloud container identifier | `project.yml:162-163` — `com.apple.developer.icloud-container-identifiers: [iCloud.com.running.stride]` | ✅ |
| CloudKit service enabled | `project.yml:164-165` — `com.apple.developer.icloud-services: [CloudKit]` | ✅ |
| Remote-notification background mode | `project.yml:194-196` — `UIBackgroundModes: [location, remote-notification, audio]` | ✅ |
| Push entitlement | `project.yml:144` — `aps-environment: $(APS_ENVIRONMENT)` | ✅ |

The push entitlement deserves specific credit. Apple's setup guide notes that
selecting CloudKit *"also adds push notifications that notify your app when
remote content changes"* `[S3]`, and the Background Modes step is separate. The
repo carries both, and splits the `aps-environment` **value** per configuration
(`project.yml:112-119`, `Debug: development` / `Release: production`) rather than
hardcoding it. That is the correct handling — an App Store distribution profile
only ever carries `production` — and the reasoning is already documented inline.

The widget extension correctly holds **no** iCloud entitlement
(`project.yml:326-330`). It reads the App Group snapshot and never opens the
store, so it has no business in the container.

### 2.2 The eight models are CloudKit-clean

Apple's constraints `[S1]`, `[S4]`, checked against every type in
`StrideSchema.models`:

| Constraint (Apple's wording) | Result |
| --- | --- |
| *"CloudKit is unable to enforce the `unique` property option"* `[S1]` | ✅ No `#Unique`, no `@Attribute(.unique)` anywhere. The only `@Attribute` use in the tree is `originalName:`. |
| *"CloudKit requires all relationships to be optional"* `[S1]` | ✅ All six relationships are optional: `TrainingPlan.weeks: [TrainingWeek]?`, `TrainingWeek.plan: TrainingPlan?`, `TrainingWeek.workouts: [ScheduledWorkout]?`, `ScheduledWorkout.week/completedWorkout/completedStrengthWorkout`, `RunWorkout.scheduledWorkout`, `StrengthWorkout.scheduledWorkout`. |
| *"All relationships must have an inverse, in case the records synchronize out of order"* `[S4]` | ✅ Every relationship pair declares its inverse on exactly one side (`TrainingPlan.swift:32`, `TrainingWeek.swift:21`, `ScheduledWorkout.swift:43,50`). |
| *"CloudKit doesn't support the Deny deletion rule"* `[S4]` | ✅ Only `.cascade` (2) and `.nullify` (2) are used. |
| *"`Undefined` and `objectID` attribute types aren't supported"* `[S4]` | ✅ None used. |
| Non-optional attributes need defaults | ✅ Every stored property is either optional or has a default (`= UUID()`, `= Date()`, `= 0`, `= ""`, `= false`). |
| Enums stored as CloudKit-representable types | ✅ Every enum is persisted as a raw `String` (`workoutTypeRaw`, `goalRaceRaw`, `phaseRaw`, …) with the typed accessor in an extension so `@Model` doesn't treat it as an attribute. `UserProfile.swift:102` documents this. |
| SQLite store required `[S2]` | ✅ File-backed store at `StrideSchema.storeURL`. |
| New container, never used with raw CloudKit `[S2]` | ✅ `iCloud.com.running.stride` is only ever touched by SwiftData; the one direct `CKContainer` use (`OnboardingSubviews.swift:277`) reads `accountStatus` and writes nothing. |

### 2.3 Explicit container selection on the sync path

The sync path passed `cloudKitDatabase: .private(…)` even before this audit — exactly the
pattern Apple prescribes for opting out of automatic discovery `[S1]`, and what makes it
deterministic. Its inline comment ("Explicit container ID so every code path targets the
same CloudKit store") stated the right intent; F1 was about the paths where that intent
was not applied. Container selection now runs through
`AppContainer.makeConfiguration`, and the identifier lives on
`StrideSchema.cloudKitContainerID` so no caller spells it out.

### 2.4 The two hand-written mitigations are the right ones

Apple names two guarantees CloudKit cannot provide. The repo addresses both:

- **No uniqueness.** `ProfileRestoreDeduplicator` (`StrideApp.swift:380-620`)
  merges duplicate profiles and retires duplicate active plans, driven from
  `.onChange(of: profiles.count)` (`StrideApp.swift:240`). Because that count is
  `@Query`-backed, it fires on CloudKit imports too, not just at launch — which
  is what makes it a real mitigation rather than a launch-time cleanup.
- **Indeterminate ordering.** *"CloudKit processes changes in an indeterminate
  order"* `[S1]`; *"All relationships must have an inverse, in case the records
  synchronize out of order"* `[S4]`. `RunWorkout.linkedScheduledWorkoutID`,
  `ScheduledWorkout.linkedRunWorkoutID`, and
  `ScheduledWorkout.linkedStrengthWorkoutID` mirror each relationship as a scalar
  UUID, and `ProfileRestoreDeduplicator.repairRelationships(in:)` re-stitches
  from them after a restore. The comment at `RunWorkout.swift:71-74` describes
  precisely the failure Apple warns about.

### 2.5 Account status and initial-sync gating

`WelcomeBackRestoreCoordinator` maps all six `CKAccountStatus` cases to distinct
user-facing copy and, critically, distinguishes `.timedOut` from `.noRemoteData`
so a returning user whose records are still arriving is never dropped into
new-user onboarding (`WelcomeBackRestoreCoordinator.swift:84-93`). It waits on a
real `NSPersistentCloudKitContainer.eventChangedNotification` import event with
`endDate != nil` (`OnboardingSubviews.swift:326-345`) rather than a fixed sleep.
This is the correct signal — SwiftData uses `NSPersistentCloudKitContainer`
underneath `[S1]` — and the 60 s fallback is a reasonable defence.

`AppContainer.configureCloudKitDiagnostics` (`AppContainer.swift:592-695`)
observes the same notification and unwraps `CKPartialErrorsByItemIDKey` and
`NSUnderlyingErrorKey` recursively. That is genuinely good diagnostics.

---

## 3. Findings

### F1 — (High) Every "local-only" store configuration still syncs to CloudKit

> ✅ **FIXED** — `AppContainer.makeConfiguration` now builds every configuration and names
> `cloudKitDatabase` on each (`.private` when mirroring, `.none` otherwise); tier 2
> recreates with the primary configuration so the "data comes back from iCloud" alert stays
> true; `IntentDataProvider`, `TestStore`, and `IntentDataProviderTests` pass `.none`.

`ModelConfiguration`'s URL-based initialiser is declared `[S5]`:

```swift
init(_ name: String? = nil, schema: Schema? = nil, url: URL,
     allowsSave: Bool = true,
     cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .automatic)
```

and `.automatic` is documented as `[S6]`:

> Enables managed CloudKit sync using the primary ubiquity container from the app's entitlements.

Core Data states the same resolution rule: *"For an app without configurations,
`NSPersistentCloudKitContainer` matches the first store description with the
first CloudKit container identifier in the entitlements"* `[S3]`.

`Stride.entitlements` contains `iCloud.com.running.stride`. Therefore **every
configuration in the app that omits `cloudKitDatabase:` enables CloudKit sync**:

| Site | Intent | Actual |
| --- | --- | --- |
| `AppContainer.swift:212` | Store opened with the iCloud Sync toggle **off** | Syncs |
| `AppContainer.swift:216` (`localConfig`) | Tier-1 fallback, "CloudKit disabled" | Syncs |
| `AppContainer.swift:421-430` | Simulator carve-out returns `false` | Syncs anyway |
| `IntentDataProvider.swift:25` | *"without CloudKit sync overhead"* | Syncs |

Four consequences, in descending severity:

1. **The user-facing iCloud Sync toggle does not turn off iCloud sync.** A user
   who switches it off, restarts as Settings instructs, and sees `Active Store:
   Local Only` (`SettingsView.swift:41-47`, `283-287`) is still uploading every
   run, plan, and route to iCloud. This is the finding that matters most: it is a
   privacy control that reports success without acting.

2. **Tier-1 fallback cannot do the job it exists for.** `AppContainer.swift:239-241`
   retries with `localConfig` only when the primary config used CloudKit, and the
   comment explains why: *"with CloudKit off, the primary config IS `localConfig`,
   so retrying the identical configuration can't succeed."* That reasoning is
   right — but because `localConfig` resolves to the same container via
   `.automatic`, the retry **is** the identical configuration in the CloudKit case
   too. Any store-open failure caused by CloudKit fails identically on retry, the
   app falls through to Tier-2 or Tier-3, and the log line at
   `AppContainer.swift:229` ("falling back to local-only at same URL") is untrue.

3. **App Intents open a second mirroring container over the same store file.**
   `IntentDataProvider.makeContainer()` is called fresh by four intents
   (`TodaysRunIntent:11`, `CoachTipIntent:20`, `WeeklySummaryIntent:11`,
   `RunWorkoutEntity:70,104`). Each builds a CloudKit-backed `ModelContainer` on
   `StrideSchema.storeURL` — the file the app already has open for mirroring.
   Apple's own schema-init sample takes explicit care to avoid this shape:
   *"Unload the persistent store before creating an instance of `ModelContainer`
   to avoid both frameworks attempting to sync data to CloudKit"* `[S1]`. The
   reads are genuinely read-only (no `insert`/`delete`/`save` in
   `IntentDataProvider.swift`), which limits the blast radius to setup work,
   duplicated import processing, and log noise rather than data corruption — but
   it is the opposite of the file's stated contract.

4. **The simulator carve-out is inert.** `shouldUseCloudKit` returns `false` and
   logs *"CloudKit disabled in simulator"*, then hands back a config that enables
   it. See also F5.

Tier-2 (`AppContainer.swift:268`) is the one case where the accident helps: the
recreated store *is* mirrored, so data does come back down from iCloud, which is
what the `storeMovedAside` alert promises the user (`AppContainer.swift:79-83`).
That promise should be kept deliberately rather than by omission.

**Fix:** pass `cloudKitDatabase: .none` — *"Disables managed CloudKit sync"*
`[S7]` — on every configuration that is meant to be local, and keep `.private(…)`
where mirroring is intended. See §5.1.

### F2 — (High) The CloudKit schema is never initialised, and no deploy step is documented

> ✅ **FIXED** — `CloudKitSchemaInitializer` (`#if DEBUG`, run with `--init-cloudkit-schema`)
> uploads the full schema following Apple's sample, called from `StrideApp.init` before the
> `ModelContainer` exists. `docs/CLOUDKIT_VALIDATION.md` gains a **Release gate** section
> covering initialisation, CloudKit Console verification, and Deploy Schema Changes.

Nothing in the tree calls `initializeCloudKitSchema()`. Apple is unambiguous
that this is a required development step, not an optimisation `[S1]`:

> You manually initialize your app's CloudKit schema during development — as the following section describes — but you need to promote that schema to production before releasing your app. CloudKit schemas are additive only, which means you're unable to delete model types or change existing model attributes after you promote a schema to production.

And on what initialisation actually does `[S4]`:

> While initializing the schema, Core Data creates a temporary instance of each distinct record type in each of the container's stores that mirror to a CloudKit database and uploads them to the iCloud servers.

Two gaps follow.

**No forced initialisation.** Without it, the development schema materialises
only for record types and fields that are actually written on a development
device. Every additive field the repo has deliberately made optional "so the
CloudKit schema stays additive" — `RunWorkout.averageCadenceStepsPerMinute`
(`RunWorkout.swift:23`), `RunWorkout.aiCoachReactionRaw` (`:85`),
`RunWorkout.distanceSeriesData` (`:65`), `RunWorkout.lapsData` (`:46`), the
pregnancy fields on `UserProfile` (`:50-63`) — reaches the server only once some
tester happens to exercise that feature. `DeletedWorkout` is the sharpest case:
it is written only when a runner deletes a HealthKit-sourced workout, so a
container where nobody did that has no `CD_DeletedWorkout` record type at all,
and deletion tombstones never propagate. `SavedRoute` and `StrengthWorkout` have
the same shape.

**No deploy-to-production step anywhere in the repo.** Apple `[S8]`:

> Apps in the App Store can access only the production environment. Before you publish your app, you must deploy the development schema to the production environment to copy over its record types, fields, and indexes.

`docs/CLOUDKIT_VALIDATION.md` covers two-device validation thoroughly but never
mentions **Deploy Schema Changes**, and neither does `AGENTS.md`. This is the
classic silent failure mode: sync works perfectly for every developer and
TestFlight tester on the development environment, then does nothing for App Store
users, because App Store builds can only see production `[S8]`. Since deployment
is additive-only and irreversible for existing fields `[S1]`, `[S8]`, it also
needs to happen *after* the schema is complete, which is what makes F2's two
halves one problem.

### F3 — (Medium) The `SavedRoute` 1 MB warning is contradicted by Apple's documentation

> ✅ **FIXED** — the comment at `SavedRoute.swift:9` now states the documented behaviour
> (automatic `_ckAsset` promotion) and records `.externalStorage` as an optional *local*
> optimisation rather than a blocked sync fix.

`SavedRoute.swift:9-13` carries a standing warning:

> NOTE: these are *not* yet marked `@Attribute(.externalStorage)`, so a very long route can push a record past the ~1 MB CKRecord limit and silently stop syncing. Enabling external storage is the correct fix but changes the persistent store format and must ship with a device-tested CloudKit migration.

Apple documents the opposite behaviour `[S9]`:

> All variable length attribute types—String, Binary Data, and Transformable—generate an additional field with a key in the form `CD_[attribute.name]_ckAsset`. If a field's value grows too large to store within the record size limit of 1MB, Core Data automatically converts the value to an external asset. Core Data transitions between the original field and its asset counterpart transparently during serialization.

So Core Data already assetises oversized `Data` fields on the CloudKit side,
per-field and transparently. `.externalStorage` is a *local* store optimisation —
it keeps large blobs out of the SQLite row — and is not a prerequisite for
syncing them. The stated risk ("silently stop syncing") does not follow from
Apple's documentation, and the deferred work item it justifies ("must ship with a
device-tested CloudKit migration") is being deferred for a reason that isn't
there.

This applies equally to `RunWorkout`'s five blob fields (`splitsData`, `lapsData`,
`heartRateSamplesData`, `routeData`, `distanceSeriesData`), which carry no such
warning — the asymmetry is itself a sign the note was a guess.

Two caveats worth keeping. Assetisation is per-field, so a record whose *many*
individually-small fields sum past 1 MB is still a theoretical problem — not the
case for any model here. And local row bloat is real: `.externalStorage` remains
a legitimate performance change on its own merits, just not a sync-correctness one.

**Fix:** correct the comment (§5.3). Treat `.externalStorage` as an optional
local optimisation, tracked separately if wanted.

### F4 — (Medium) The tests assert the persistence *label*, not the persistence *behaviour*

> ✅ **FIXED** — `StrideTests/CloudKitConfigurationTests.swift` asserts
> `cloudKitContainerIdentifier` on the built configuration for every combination of
> in-memory / sync-on / sync-off, plus that the fallback genuinely differs from the primary.
> `CloudKitDiagnosticsTests` covers the event and error flattening.

`AppContainerTests.syncDisabledUsesLocalStore` (`AppContainerTests.swift:16-38`)
asserts `container.persistenceMode == .localOnly`. But `persistenceMode` is a
value `AppContainer` assigns to itself at `:225` from the same `cloudKitEnabled`
boolean that F1 shows is not what SwiftData acts on. The test passes today and
would keep passing under F1's fix or a regression of it — it cannot distinguish
them, because nothing in the suite ever inspects a `ModelConfiguration`'s
`cloudKitDatabase`.

`cloudKitFailureFallsBackToLocalStore` (`:39-80`) has the same shape: it injects
a throwing factory and asserts the retry count and the resulting label. It proves
the tier logic runs; it cannot prove the retry uses a different configuration —
which is exactly F1(2).

**Fix:** extract configuration-building into a testable pure function and assert
on it (§5.2). This is the only part of F1 that is verifiable off-device, which
makes it the highest-value test in this document.

### F5 — (Low) The simulator carve-out is both non-functional and unnecessary

> ✅ **FIXED** — kept and now effective. Resolved in favour of keeping it, for a reason this
> write-up originally missed: the unit-test suite runs in the simulator and builds real
> file-backed containers, so without the carve-out every test run writes into the team's
> development container. `shouldUseCloudKit`, `AGENTS.md`, and
> `docs/CLOUDKIT_VALIDATION.md` now all say that.

`AppContainer.shouldUseCloudKit` (`:421-430`) returns `false` under
`targetEnvironment(simulator)`. `AGENTS.md:192` states this as a rule
("Simulator builds intentionally disable CloudKit") and
`docs/CLOUDKIT_VALIDATION.md:3` builds its whole premise on it.

Two problems. First, per F1 it doesn't disable anything. Second, Apple states the
carve-out isn't needed `[S2]`:

> You can run and test Core Data with CloudKit apps using Simulator. You may also test with multiple physical devices logged into the same iCloud account.

Device testing remains the right call for *validating* sync — two-device
propagation, background push delivery, and account-state transitions genuinely
need hardware. But that is a validation-strategy argument, not a reason the store
must open unmirrored in the simulator. Whichever way this is resolved, the code
and the two docs should agree; today all three describe a behaviour that isn't
happening.

### F6 — (Low) `CloudKitDebugView` shows no CloudKit state

> ✅ **FIXED** — the screen now shows `Active Store`, **Mirroring To** (read back off the
> live configuration), live `CKAccountStatus`, and the recent
> `NSPersistentCloudKitContainer` events via `AppContainer.recentCloudKitEvents`.

`CloudKitDebugView` renders local SwiftData rows plus the sync toggle. Its own
footer is honest about it — *"local SwiftData records mirrored by CloudKit plus
iCloud key-value settings"* (`:66`) — but the screen is the one place a TestFlight
tester is sent to diagnose sync, and it cannot answer any of the questions
`docs/CLOUDKIT_VALIDATION.md` asks. `AppContainer` already computes everything
missing: `persistenceMode`, the container identifier, and the last
setup/import/export event with its error text.

**Fix:** surface `CKAccountStatus`, the active `persistenceMode`, the container
ID, and the last few CloudKit events on that screen, so validation doesn't depend
on the Pulse console.

---

## 4. Deliberately not flagged

Things checked that turned out fine, recorded so the next pass doesn't re-derive them:

- **`.cascade` delete rules** (`TrainingPlan.weeks`, `TrainingWeek.workouts`) are
  permitted; only `.deny` is unsupported `[S4]`. Cascades can still arrive
  non-atomically across devices, which is what
  `ProfileRestoreDeduplicator.repairRelationships` cleans up.
- **`#Index` macros** on all eight models describe local SQLite indexes and have
  no CloudKit schema counterpart. Harmless.
- **`@Attribute(originalName:)` legacy fields** are all optional, so they read as
  additive fields on the CloudKit side — the right way to absorb a rename.
- **`context.delete(model:)` in `PlanLifecycleService.resetAllData`** removes
  models *"during the next save operation"* `[S10]`, i.e. through the context, so
  deletions export normally.
- **Store location** (`URL.applicationSupportDirectory`, not the App Group) is
  correct: only the app process should open the mirrored store, and the widgets
  read the snapshot file instead.
- **The iCloud Sync toggle is device-local** (`AppSettings.swift:44`,
  `deviceLocalKeys`), so turning sync off on one device does not cascade through
  KVS to the others. Correct, and worth keeping when F1 is fixed — the fix makes
  this toggle meaningful for the first time.

---

## 5. The fixes

All applied. Kept in full because each records a constraint the code has to go on
satisfying, not just a change that was made. §5.2 is the only one verifiable in CI.

### 5.1 Make every non-sync configuration explicit — F1, F5

```swift
// AppContainer.swift:203-216
if inMemory {
    config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                cloudKitDatabase: .none)
} else if cloudKitEnabled {
    config = ModelConfiguration(schema: schema, url: storeURL,
                                cloudKitDatabase: .private(ckContainerID))
} else {
    config = ModelConfiguration(schema: schema, url: storeURL,
                                cloudKitDatabase: .none)   // ← was .automatic
}

let localConfig = ModelConfiguration(schema: schema, url: storeURL,
                                     cloudKitDatabase: .none)   // ← was .automatic
```

Also `AppContainer.swift:413` (emergency in-memory) and
`IntentDataProvider.swift:25` — the latter is the one-line change that makes its
own doc comment true.

Two consequences to decide deliberately, not inherit:

- **Tier 2 currently recovers via CloudKit by accident.** With `localConfig`
  set to `.none`, a store moved aside for a migration failure would be recreated
  *unmirrored*, and the `storeMovedAside` alert's promise — *"if you had iCloud
  Sync on, your data will come back down from iCloud shortly"*
  (`AppContainer.swift:79-83`) — would stop being true. Tier 2 should therefore
  recreate with `.private(ckContainerID)` when `cloudKitEnabled`, and `.none`
  otherwise. This is a behaviour the fix must preserve on purpose.
- **Tier 1's guard becomes correct.** Once `localConfig` is genuinely
  CloudKit-free, the retry at `:239-241` is a materially different configuration
  and can actually recover a CloudKit-caused open failure — which is what the
  comment already claims.

Device validation for this change: turn iCloud Sync off, restart, create a run,
and confirm in CloudKit Console that no new record appears — the assertion the
current `Active Store: Local Only` display implies but does not support.

### 5.2 Extract and test the configuration decision — F4

Move config construction out of `init` into a static pure function:

```swift
static func makeConfiguration(schema: Schema, storeURL: URL,
                              inMemory: Bool, cloudKitEnabled: Bool,
                              containerID: String) -> ModelConfiguration
```

Then assert on `configuration.cloudKitContainerIdentifier` (exposed by
`ModelConfiguration` `[S11]`) — `nil` when sync is off or in-memory,
`"iCloud.com.running.stride"` when on. This is the regression test F1 needs and
it runs in the simulator, no device required.

### 5.3 Correct the `SavedRoute` blob note — F3

Replace the warning at `SavedRoute.swift:9-13` with what `[S9]` documents: Core
Data auto-promotes oversized variable-length fields to `CD_<field>_ckAsset`, so
the blobs sync regardless. Keep `.externalStorage` as an optional local-storage
improvement if it is still wanted, tracked on its own merits in
`docs/FEATURE_IMPROVEMENTS_2026-07.md`.

### 5.4 Add schema initialisation and a deploy step — F2

Add a `#if DEBUG` `initializeCloudKitSchema()` pass following Apple's SwiftData
sample `[S1]` — build the `NSPersistentStoreDescription` from
`ModelConfiguration.url`, set `cloudKitContainerOptions`, load synchronously,
initialise, then **remove the store before constructing the `ModelContainer`**,
which is the step the sample calls out explicitly. Run it once per schema change
on a development device, not on every launch.

Then add to `docs/CLOUDKIT_VALIDATION.md` a release-gate section: after any change
to `StrideSchema.models` or to any `@Model`'s stored properties, re-run schema
initialisation on a development device, verify the new record types and fields in
CloudKit Console, and **Deploy Schema Changes** to production before the build
ships `[S8]`. Note that deployment is additive-only and cannot be undone `[S1]`.

### 5.5 Reconcile the simulator claim — F5

Once §5.1 lands, either keep `shouldUseCloudKit`'s simulator branch (now
effective) and update `AGENTS.md:192` to say device testing is a *validation*
requirement rather than a technical one, or drop the branch on the strength of
`[S2]`. Either way `AGENTS.md`, `docs/CLOUDKIT_VALIDATION.md:3`, and the code
should stop disagreeing.

### 5.6 Put CloudKit state on the CloudKit debug screen — F6

Add `CKAccountStatus`, `persistenceMode`, the container ID, and the last few
`NSPersistentCloudKitContainer` events to `CloudKitDebugView`.

---

## 6. Device validation still owed

The code changes are in; none of the below has been run. Everything here needs hardware,
which is why it could not be done in the same pass.

1. **The sync-off assertion.** Turn iCloud Sync off, restart, confirm
   `Settings > CloudKit Debug > Mirroring To` reads `Not mirroring`, create a run, and
   confirm no new record appears in CloudKit Console. This is the one that proves F1 is
   actually fixed — `CloudKitConfigurationTests` proves the configuration is right, not
   that SwiftData honours it.
2. **A full pass of `docs/CLOUDKIT_VALIDATION.md`** with sync back on, two devices. The
   fallback tiers changed shape (tier 1 is now genuinely a different configuration; tier 2
   recreates mirrored), so the fallback section matters as much as the happy path.
3. **The release gate** — run `--init-cloudkit-schema` once on a device, verify the record
   types in CloudKit Console, and **Deploy Schema Changes**. Must precede the next App
   Store submission, and note that deployment is additive-only and irreversible.
4. **A `xcodegen generate` + full build and test run.** No Swift toolchain was available
   where these changes were written, so nothing here has been compiled.

---

## 7. Sources

All Apple Developer Documentation, retrieved 2026-07-28.

- `[S1]` [Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices) — SwiftData. Required capabilities; the `@Attribute`/`@Relationship` CloudKit limitation table; schema initialisation sample; `cloudKitDatabase` container selection; production promotion.
- `[S2]` [Mirroring a Core Data store with CloudKit](https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit) — eligibility (SQLite store, no unique constraints / undefined attributes / required relationships); existing-container incompatibility; simulator testing.
- `[S3]` [Setting Up Core Data with CloudKit](https://developer.apple.com/documentation/coredata/setting-up-core-data-with-cloudkit) — iCloud + CloudKit + push + remote-notification background mode; entitlement-to-store-description matching rule.
- `[S4]` [Creating a Core Data Model for CloudKit](https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit) — full model limitation table (unique constraints, optional relationships, required inverses, no Deny rule, unsupported attribute types); what `initializeCloudKitSchema()` does.
- `[S5]` [`ModelConfiguration.init(_:schema:url:allowsSave:cloudKitDatabase:)`](https://developer.apple.com/documentation/swiftdata/modelconfiguration/init(_:schema:url:allowssave:cloudkitdatabase:)) — the `cloudKitDatabase: = .automatic` default.
- `[S6]` [`ModelConfiguration.CloudKitDatabase.automatic`](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct/automatic) — *"Enables managed CloudKit sync using the primary ubiquity container from the app's entitlements."*
- `[S7]` [`ModelConfiguration.CloudKitDatabase.none`](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct/none) — *"Disables managed CloudKit sync."*
- `[S8]` [Deploying an iCloud Container's Schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema) — App Store builds see production only; additive-only deployment.
- `[S9]` [Reading CloudKit Records for Core Data](https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data) — `CD_` prefixing; attribute-type mapping; automatic `_ckAsset` promotion past the 1 MB record limit.
- `[S10]` [`ModelContext.delete(model:where:includeSubclasses:)`](https://developer.apple.com/documentation/swiftdata/modelcontext/delete(model:where:includesubclasses:)) — removal occurs during the next save.
- `[S11]` [`ModelConfiguration`](https://developer.apple.com/documentation/swiftdata/modelconfiguration) — `cloudKitContainerIdentifier`, `cloudKitDatabase` properties.
