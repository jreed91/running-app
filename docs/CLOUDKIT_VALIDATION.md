# CloudKit Validation

This app disables CloudKit on the simulator, so real save/retrieve validation must be done on physical devices signed into iCloud.

## Preconditions

- Build a device-signed app with the `iCloud.com.jacobreedrunningapp` container enabled.
- Use two physical iPhones signed into the same Apple ID.
- In the app, confirm `Settings > App > iCloud Sync` is enabled.
- In the app, confirm `Settings > App > Active Store` shows `CloudKit`.
- Open `Settings > About > Pulse Console` before and after each step to inspect `CloudKit` log entries.

## Expected Pulse Evidence

Look for `CloudKit` log lines with these event types:

- `setup finished`
- `export started` then `export finished`
- `import started` then `import finished`

If an event fails, Pulse will include the error text in the log line.

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
   Restart the app. Expected result: `Active Store` changes to `Local Only`.

2. Make a local change while sync is off.
   Expected result: data still saves and reloads on that device.

3. Turn iCloud sync back on and restart the app.
   Expected result: `Active Store` returns to `CloudKit`.

4. Check Pulse Console after relaunch.
   Expected result: `setup`, then `export` and/or `import` events appear without store creation errors.

## Failure Signs

- `Active Store` shows `Local Fallback`, `Recreated Local Store`, or `Emergency In-Memory` on a real device that should be cloud-backed.
- Pulse never shows a `CloudKit export finished` event after creating new data.
- Device B stays empty after Device A exported successfully.
- Duplicate profiles or plans appear after import.
- Pulse logs repeated CloudKit setup or import failures.

## Notes

- Simulator test coverage validates the local persistence graph and restore coordination, but not Apple's live CloudKit transport.
- Pulse is the source of truth for manual CloudKit event verification during development and TestFlight validation.
