import CoreData
import Foundation
import SwiftData
import Testing
@testable import Stride

/// Checks that `cloudkit/Stride.ckdb`, the schema the `CloudKit schema` workflow imports
/// into Development, has a record type and field for everything the SwiftData models
/// store.
///
/// This is what replaces running the app with `--init-cloudkit-schema`: a model change
/// that the schema file does not cover fails here, with the lines to add, instead of
/// surfacing after release as data that never syncs for App Store users.
///
/// The names follow `NSPersistentCloudKitContainer`'s mapping: entity `RunWorkout` is
/// record type `CD_RunWorkout` (a sub-entity lives in its root entity's record type),
/// attribute `distance` is field `CD_distance`, and a to-one relationship is a `CD_`
/// field holding the related record's name. The check is on names only. A suggested
/// type is given for missing fields, but `cktool validate-schema` in the workflow is
/// what checks the file is well formed.
struct CloudKitSchemaFileTests {

    /// The file in the checkout, beside this test's folder (the simulator shares the
    /// Mac's file system).
    static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("cloudkit/Stride.ckdb")

    static var schemaFileIsCheckedIn: Bool {
        FileManager.default.fileExists(atPath: schemaURL.path)
    }

    @Test(
        "The CloudKit schema file covers every stored model field",
        .enabled(if: CloudKitSchemaFileTests.schemaFileIsCheckedIn, "cloudkit/Stride.ckdb is not checked in yet")
    )
    func schemaFileCoversTheModels() throws {
        let file = CKDBSchemaFile(try String(contentsOf: Self.schemaURL, encoding: .utf8))
        #expect(!file.recordTypes.isEmpty, "No RECORD TYPE found in cloudkit/Stride.ckdb: has its format changed?")

        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: StrideSchema.models))
        let missing = Self.missingLines(model: model, file: file)

        #expect(
            missing.isEmpty,
            """
            cloudkit/Stride.ckdb is missing schema the models store. Add these lines inside \
            the record type shown (match the format of the lines around them), and the \
            CloudKit schema workflow imports them into Development when the change reaches main:
            \(missing.joined(separator: "\n"))
            """
        )
    }

    @Test("The .ckdb reader finds record types and fields")
    func readerParsesTheExportFormat() {
        let file = CKDBSchemaFile(
            """
            DEFINE SCHEMA

                RECORD TYPE CD_RunWorkout (
                    "___createTime" TIMESTAMP,
                    "___recordID"   REFERENCE QUERYABLE,
                    CD_distance     DOUBLE,
                    "CD_entityName" STRING,
                    GRANT WRITE TO "_creator",
                    GRANT READ TO "_world"
                );

                RECORD TYPE Users (
                    roles LIST<INT64>
                );
            """
        )
        #expect(file.recordTypes["CD_RunWorkout"] == ["___createTime", "___recordID", "CD_distance", "CD_entityName"])
        #expect(file.recordTypes["Users"] == ["roles"])
    }

    // MARK: - Expected names

    static func missingLines(model: NSManagedObjectModel, file: CKDBSchemaFile) -> [String] {
        var missing: [String] = []

        for entity in model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            var root = entity
            while let parent = root.superentity { root = parent }
            let recordType = "CD_" + (root.name ?? "")

            guard let fields = file.recordTypes[recordType] else {
                if !missing.contains(where: { $0.hasPrefix("RECORD TYPE \(recordType) ") }) {
                    missing.append("RECORD TYPE \(recordType) (whole record type missing)")
                }
                continue
            }

            func require(_ field: String, hint: String) {
                // A composite or flattened value can be stored as several `CD_name_…`
                // fields, so any of those counts.
                let present = fields.contains(field) || fields.contains { $0.hasPrefix(field + "_") }
                if !present { missing.append("\(recordType): \(field) \(hint)") }
            }

            require("CD_entityName", hint: "STRING")

            for (name, attribute) in entity.attributesByName.sorted(by: { $0.key < $1.key })
            where !attribute.isTransient {
                require("CD_" + name, hint: Self.hint(for: attribute))
            }

            for (name, relationship) in entity.relationshipsByName.sorted(by: { $0.key < $1.key })
            where !relationship.isTransient && !relationship.isToMany {
                // The to-many side is not stored: CloudKit rebuilds it from the to-one
                // side's reference.
                require("CD_" + name, hint: "STRING")
            }
        }

        return missing
    }

    static func hint(for attribute: NSAttributeDescription) -> String {
        switch attribute.attributeType {
        case .stringAttributeType, .UUIDAttributeType, .URIAttributeType:
            return "STRING"
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType, .booleanAttributeType:
            return "INT64"
        case .doubleAttributeType, .floatAttributeType, .decimalAttributeType:
            return "DOUBLE"
        case .dateAttributeType:
            return "TIMESTAMP"
        case .binaryDataAttributeType, .transformableAttributeType:
            return "BYTES (plus \(("CD_" + attribute.name) + "_ckAsset") ASSET for large values)"
        default:
            return "(copy the type from a similar field, or export Development after one --init-cloudkit-schema run)"
        }
    }
}

/// The record types and field names in a CloudKit schema file, as `cktool export-schema`
/// writes it. Only names are read: types, indexes and GRANT lines are skipped.
struct CKDBSchemaFile {
    private(set) var recordTypes: [String: Set<String>] = [:]

    init(_ text: String) {
        let quotes = CharacterSet(charactersIn: "\"")
        var current: String?

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("--") { continue }

            if line.uppercased().hasPrefix("RECORD TYPE ") {
                let rest = line.dropFirst("RECORD TYPE ".count).trimmingCharacters(in: .whitespaces)
                let name = String(rest.prefix { $0 != "(" && !$0.isWhitespace })
                    .trimmingCharacters(in: quotes)
                current = name
                recordTypes[name, default: []] = []
                continue
            }

            guard let recordType = current else { continue }
            if line.hasPrefix(")") {
                current = nil
                continue
            }
            if line.uppercased().hasPrefix("GRANT ") { continue }

            let field = String(line.prefix { !$0.isWhitespace && $0 != "," })
                .trimmingCharacters(in: quotes)
            if !field.isEmpty { recordTypes[recordType]?.insert(field) }
        }
    }
}
