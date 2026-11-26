# CloudKit schema

`Stride.ckdb` is the CloudKit schema for the `iCloud.com.running.stride` container, in the
text format Apple's `cktool` reads and writes. It replaces running the app with
`--init-cloudkit-schema` to get new record types and fields into the Development
environment.

## How a schema change ships

1. Change a `@Model`. `CloudKitSchemaFileTests` (in `StrideTests`) fails and lists the
   record types and fields `Stride.ckdb` is missing, with a suggested type for each.
2. Add those lines to `Stride.ckdb`, inside the record type named, in the same format as
   the lines around them. Only add lines: the import replaces the Development schema, so a
   line taken out would drop that field from Development. The workflow refuses to import
   a file that is missing anything Development has.
3. Open the PR. The **CloudKit schema** workflow validates the file against Development.
4. Merge. The workflow imports the file into Development and its run summary lists what
   **Deploy Schema Changes** would add to Production.
5. In [CloudKit Console](https://icloud.developer.apple.com), open the container and press
   **Deploy Schema Changes** before the release ships. `cktool` has no command for this:
   promoting to Production is Console only. Deploying is additive and cannot be undone.

You can also run the workflow by hand from the Actions tab: `import` does step 4, and
`export` saves the current Development and Production schemas as an artifact without
changing anything.

## Names

`NSPersistentCloudKitContainer` names a model `RunWorkout` record type `CD_RunWorkout`,
attribute `distance` field `CD_distance`, and a to-one relationship `route` field
`CD_route` (the related record's name, a `STRING`). Every record type also has
`CD_entityName`. Large `Data` values get a companion `CD_<name>_ckAsset` `ASSET` field. The
to-many side of a relationship is not stored.

## One-time setup

The workflow needs a CloudKit **management token** (it can change the schema but cannot
read or write anyone's data):

1. Sign in to [CloudKit Console](https://icloud.developer.apple.com), open your account
   **Settings** (top right) and create a **CloudKit Management Token** for team
   `VMNPGK3Q29`. Copy it: it is shown once. It lasts a year.
2. In GitHub, open the repo's **Settings → Secrets and variables → Actions → New
   repository secret**, name it `CLOUDKIT_MANAGEMENT_TOKEN` and paste the token.
3. Run the **CloudKit schema** workflow with action `export`. Download the
   `cloudkit-schemas` artifact and check in its `development-before.ckdb` as
   `cloudkit/Stride.ckdb`. From then on that file is the source of truth.

When the token expires the workflow fails at "Check the management token" or with an
authentication error; make a new one and replace the secret.

## Running cktool on a Mac

```sh
export CLOUDKIT_MANAGEMENT_TOKEN=…   # or: xcrun cktool save-token --type management
xcrun cktool validate-schema --team-id VMNPGK3Q29 --container-id iCloud.com.running.stride \
  --environment development --file cloudkit/Stride.ckdb
xcrun cktool import-schema   --team-id VMNPGK3Q29 --container-id iCloud.com.running.stride \
  --environment development --file cloudkit/Stride.ckdb
```

## Record types that aren't SwiftData's

`FriendWeek` is written by hand (`CloudKitTrainingGroupService`, "Train with friends"), not
by `NSPersistentCloudKitContainer`, so it has no `CD_` prefix and `CloudKitSchemaFileTests`
doesn't check it. Each training group is a custom zone (`TrainingGroup-<UUID>`) in its
owner's private database, shared with a zone-wide `CKShare`; members reach it through the
shared database. Reads use zone changes, not queries, so no field needs `QUERYABLE`.

The first time a group is created against Development, CloudKit adds the system
`cloudkit.share` record type there. Export the Development schema after that and add its
`cloudkit.share` block to this file, or the next import is refused for missing it.
