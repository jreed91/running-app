# CloudKit Validation

This app disables CloudKit on the simulator (`AppContainer.shouldUseCloudKit`), so real
save/retrieve validation must be done on physical devices signed into iCloud. The reason
is not a platform limitation — Apple states you can test Core Data with CloudKit in
Simulator — it is that the unit-test suite runs there and builds real file-backed
containers, and without the carve-out every test run would write fixtures into the team's
development container.

> **Before you validate anything, check §Release gate below.** Sync working on your
> device proves nothing about the shipped app if the schema has not been deployed:
> development and TestFlight builds talk to the CloudKit *development* environment, and
> App Store builds can only see *production*.

## Release gate: deploy the schema

Do this after **any** change to `StrideSchema.models` or to a `@Model`'s stored
properties — including adding an optional field — and before the build ships.

1. Set `--init-cloudkit-schema` in the scheme's *Arguments Passed On Launch* and run once
   on a device signed into iCloud (`CloudKitSchemaInitializer`, `#if DEBUG` only). This
   uploads a temporary instance of **every** record type and field, then deletes them.
   Without it the development schema only contains what someone happened to exercise, so a
   field nobody used is not on the server and cannot be deployed. Unset the argument after.
2. Sign in to [CloudKit Console](https://icloud.developer.apple.com), choose the
   `iCloud.com.running.stride` container, and confirm the new record types / fields appear
   in **Development**. Record types are prefixed `CD_`.
3. Select **Deploy Schema Changes**, review, and deploy.

Deployment is **additive only and irreversible**: once a record type or field is in
production it cannot be deleted or have its type changed. Get the schema right before
deploying, not after.

Signs this step was skipped: sync works for every developer and TestFlight tester and does
nothing for App Store users; or one model type syncs while a newer one silently does not.

## Preconditions

- Build a device-signed app with the `iCloud.com.running.stride` container enabled.
- Use two physical iPhones signed into the same Apple ID.
- In the app, confirm `Settings > App > iCloud Sync` is enabled.
- In the app, confirm `Settings > App > Active Store` shows `CloudKit`.
- Open `Settings > CloudKit Debug` and confirm **Mirroring To** shows
  `iCloud.com.running.stride` and **iCloud Account** shows `Available`. `Mirroring To` is
  read back off the configuration SwiftData was actually handed, so it — not the sync
  toggle, and not `Active Store` — is what says this launch is really syncing.
- Open `Settings > About > Pulse Console` before and after each step to inspect `CloudKit` log entries.

## Expected Sync Evidence

`Settings > CloudKit Debug > Recent Sync Events` lists these for the current launch, and
Pulse keeps the full history under the `CloudKit` label. Look for:

- `setup finished`
- `export started` then `export finished`
- `import started` then `import finished`

If an event fails, both surfaces include the error text. Pulse additionally expands the
per-item causes inside a partial failure, which is where a batch error's real reason lives.

## Validation Pass

1. Fresh install on Device A.
   Create a profile and generate a plan. Expected result: the profile, active plan, weeks, and scheduled workouts all appear locally.

2. Confirm export on Device A.
   Open Pulse Console and verify at least one `CloudKit export finished` event after creating the profile and plan.

3. Fresh install on Device B with the same Apple ID.
   Launch the app and wait through the welcome-back restore flow. Expected result: the existing profile and active plan appear without creating a duplicate profile.

4. Confirm import on Device B.
   Open Pulse Console and verify `CloudKit import finished`. Expected result: imported data matches Device A.

5. Update data on Device A.
   Edit the profile, complete a workout, or regenerate the plan. Expected result: Pulse shows another `export finished`.

6. Confirm the update on Device B.
   Relaunch or foreground the app and verify the same change arrives. Expected result: Pulse shows `import finished` and the edited data matches Device A.

7. Delete data that should sync.
   Remove a route, workout, or plan item that uses CloudKit-backed persistence. Expected result: the deletion propagates to Device B after import completes.

## Fallback Validation

1. On a device with existing data, turn off `Settings > App > iCloud Sync`.
   Restart the app. Expected result: `Active Store` changes to `Local Only`, and
   `Settings > CloudKit Debug > Mirroring To` reads `Not mirroring`.

2. Make a local change while sync is off.
   Expected result: data still saves and reloads on that device, **and no new record for it
   appears in CloudKit Console**. This is the assertion the toggle exists for: before F1
   was fixed, `Active Store` read `Local Only` while the store kept uploading.

3. Turn iCloud sync back on and restart the app.
   Expected result: `Active Store` returns to `CloudKit`.

4. Check Pulse Console after relaunch.
   Expected result: `setup`, then `export` and/or `import` events appear without store creation errors.

## Failure Signs

- `Active Store` shows `Local Fallback`, `Recreated Local Store`, or `Emergency In-Memory` on a real device that should be cloud-backed.
- `Mirroring To` reads `Not mirroring` while `iCloud Sync` is on.
- No `export finished` event after creating new data.
- Device B stays empty after Device A exported successfully.
- Duplicate profiles or plans appear after import.
- Repeated CloudKit setup or import failures in the log.
- A record type or field is missing in CloudKit Console → the release gate above was skipped.

## Notes

- Simulator test coverage validates the local persistence graph, restore coordination, and
  which stores mirror (`CloudKitConfigurationTests`) — but not Apple's live CloudKit transport.
- `Settings > CloudKit Debug` is the fastest read on the current launch; Pulse holds the
  full event history and expands partial-failure causes.
