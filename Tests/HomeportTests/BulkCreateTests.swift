import EventKit
import XCTest
@testable import Homeport

/// `reminders_bulk_create` accepts nested objects, and nested objects are the
/// one place this server's generic argument checking cannot reach:
/// `MCPServer.unknownArguments` compares TOP-LEVEL keys against the schema and
/// has no way to see inside `items[]`. These tests cover the hand-rolled
/// replacement, and the drift between it and `reminders_create` that would
/// otherwise be invisible until a caller lost a field.
///
/// All of it is pure — no EventKit, so no TCC grant and no reminders created.
final class BulkCreateTests: XCTestCase {

    private func tool(_ name: String) -> Tool? {
        ReminderTools.all.first { $0.name == name }
    }

    // MARK: - Per-item validation

    func testValidItemPasses() throws {
        try ReminderTools.validateBulkItem(
            ["title": "Ship it", "due": "2026-09-10", "priority": "high"], at: 0)
    }

    func testUnknownItemFieldIsRejected() {
        XCTAssertThrowsError(
            try ReminderTools.validateBulkItem(["name": "Ship it"], at: 3)
        ) { error in
            guard let e = error as? ToolError else { return XCTFail("expected ToolError") }
            // The index matters: with 50 items, "one of them is wrong" is not
            // an actionable error message.
            XCTAssertTrue(e.message.contains("items[3]"), e.message)
            XCTAssertTrue(e.message.contains("name"), e.message)
            // And it must name what IS accepted, or a model cannot self-correct.
            XCTAssertTrue(e.message.contains("title"), e.message)
        }
    }

    func testMultipleUnknownFieldsAreAllNamed() {
        XCTAssertThrowsError(
            try ReminderTools.validateBulkItem(["title": "x", "when": "y", "who": "z"], at: 0)
        ) { error in
            let message = (error as? ToolError)?.message ?? ""
            XCTAssertTrue(message.contains("when"), message)
            XCTAssertTrue(message.contains("who"), message)
        }
    }

    // MARK: - Drift

    /// The load-bearing one. `items[]` is documented as taking "the same fields
    /// as reminders_create", and nothing enforces that but this test: add a
    /// field to reminders_create and the bulk path would silently reject it as
    /// unknown, which reads to a caller as a schema bug rather than an omission.
    func testItemFieldsMatchRemindersCreateExactly() throws {
        let create = try XCTUnwrap(tool("reminders_create"))
        let properties = try XCTUnwrap(create.inputSchema.object("properties"))
        XCTAssertEqual(
            ReminderTools.bulkItemFields, Set(properties.keys),
            "reminders_bulk_create's items[] fields have drifted from reminders_create. "
            + "Add the new field to ReminderTools.bulkItemFields (and to the item schema "
            + "description), or the bulk path will reject it as unknown.")
    }

    // MARK: - Registration

    func testToolIsRegisteredAndRequiresWrite() throws {
        XCTAssertNotNil(tool("reminders_bulk_create"), "tool is not in ReminderTools.all")
        // Explicit, not inherited from the fail-closed default: Auth.toolScopes
        // is the table you read to answer "what can a read-only node do?", and
        // an absent entry answers it only by accident.
        XCTAssertNotNil(Auth.toolScopes["reminders_bulk_create"],
                        "missing an explicit Auth.toolScopes entry")
        XCTAssertEqual(Auth.requiredScope(forTool: "reminders_bulk_create"), .write)
    }

    func testSchemaDeclaresItemsAsRequired() throws {
        let bulk = try XCTUnwrap(tool("reminders_bulk_create"))
        let required = bulk.inputSchema["required"] as? [String] ?? []
        XCTAssertTrue(required.contains("items"), "items must be required")
        let properties = try XCTUnwrap(bulk.inputSchema.object("properties"))
        for key in ["items", "list", "listId", "stopOnError"] {
            XCTAssertNotNil(properties[key], "schema is missing `\(key)`")
        }
    }

    /// `additionalProperties: false` plus the top-level check is what turns a
    /// misspelled argument into a correction instead of a silently unfiltered
    /// call. The bulk tool must not opt out of it.
    func testSchemaRejectsAdditionalProperties() throws {
        let bulk = try XCTUnwrap(tool("reminders_bulk_create"))
        XCTAssertEqual(bulk.inputSchema["additionalProperties"] as? Bool, false)
    }
}

/// `reminders_bulk_delete` is the one tool that can erase a hundred records in
/// a single call, so its guard rails get their own coverage. Still pure — the
/// schema and registration are assertable without EventKit.
final class BulkDeleteTests: XCTestCase {

    private func tool(_ name: String) -> Tool? {
        ReminderTools.all.first { $0.name == name }
    }

    func testRegisteredClassifiedAndScoped() throws {
        XCTAssertNotNil(tool("reminders_bulk_delete"))
        XCTAssertEqual(Auth.toolScopes["reminders_bulk_delete"], .write)
        // Explicitly present, not inherited from the fail-closed default.
        XCTAssertNotNil(Untrusted.toolTrust["reminders_bulk_delete"])
    }

    /// The preview is the safety property, so every gate has to be a declared,
    /// discoverable argument — a destructive tool whose guard is undocumented is
    /// a guard a caller will not know to clear deliberately.
    ///
    /// Nothing is schema-`required`: `ids` and `filter` are an either/or the
    /// handler enforces (a schema cannot express XOR), and `confirmDelete` is
    /// deliberately optional so that omitting it PREVIEWS rather than errors.
    func testEveryGateIsDeclaredAndNothingIsSchemaRequired() throws {
        let bulk = try XCTUnwrap(tool("reminders_bulk_delete"))
        let properties = try XCTUnwrap(bulk.inputSchema.object("properties"))
        for key in ["ids", "filter", "expectedCount", "confirmDelete", "stopOnError"] {
            XCTAssertNotNil(properties[key], "schema is missing `\(key)`")
        }
        XCTAssertNil(bulk.inputSchema["required"],
                     "ids/filter is an XOR the handler enforces, and confirmDelete must stay "
                     + "optional so its absence previews")
    }

    /// Shares the batch cap with bulk create, so the two cannot drift into
    /// different limits that a caller has to remember separately.
    func testSharesTheBatchCap() {
        XCTAssertEqual(ReminderTools.bulkMaxItems, 100)
    }
}


/// The targeting layer shared by bulk update and bulk delete. Pure — filter
/// validation needs no EventKit and no grant.
final class BatchTargetTests: XCTestCase {

    func testUnknownFilterFieldIsRejected() {
        XCTAssertThrowsError(try BatchTarget.validateFilter(["lst": "Inbox"])) { error in
            let m = (error as? ToolError)?.message ?? ""
            XCTAssertTrue(m.contains("lst"), m)
            XCTAssertTrue(m.contains("status"), "must name the accepted set: \(m)")
        }
    }

    /// An empty filter matches everything. For a tool that deletes, "you passed
    /// no constraints" must not quietly mean "all of them".
    func testEmptyFilterIsRejected() {
        XCTAssertThrowsError(try BatchTarget.validateFilter([:])) { error in
            XCTAssertTrue(((error as? ToolError)?.message ?? "").contains("every reminder"))
        }
    }

    func testValidFilterPasses() throws {
        try BatchTarget.validateFilter(["list": "Inbox", "status": "completed"])
    }

    /// expectedCount is what makes the preview structural rather than advisory:
    /// the value cannot be known without having previewed.
    func testFilterFieldVocabularyMatchesRemindersQuery() throws {
        let query = try XCTUnwrap(ReminderTools.all.first { $0.name == "reminders_query" })
        let queryKeys = Set(try XCTUnwrap(query.inputSchema.object("properties")).keys)
        XCTAssertTrue(BatchTarget.filterFields.isSubset(of: queryKeys),
                      "a filter must speak the reminders_query vocabulary, not a second dialect. "
                      + "Not in reminders_query: \(BatchTarget.filterFields.subtracting(queryKeys))")
    }
}

final class BulkUpdateTests: XCTestCase {

    func testRegisteredClassifiedAndScoped() throws {
        XCTAssertNotNil(ReminderTools.all.first { $0.name == "reminders_bulk_update" })
        XCTAssertEqual(Auth.toolScopes["reminders_bulk_update"], .write)
        XCTAssertNotNil(Untrusted.toolTrust["reminders_bulk_update"])
    }

    /// The load-bearing exclusion. One `notes` value written across a batch
    /// overwrites fifty different bodies rather than editing them — the same
    /// class of silent data loss contacts_update grew add/remove semantics to
    /// avoid. `title` is excluded for the same reason.
    func testTitleAndNotesAreNotBulkSettable() {
        XCTAssertFalse(ReminderTools.bulkUpdateFields.contains("title"))
        XCTAssertFalse(ReminderTools.bulkUpdateFields.contains("notes"))
        XCTAssertTrue(ReminderTools.bulkUpdateFields.contains("list"))
        XCTAssertTrue(ReminderTools.bulkUpdateFields.contains("completed"))
    }

    func testEverySettableFieldIsDeclaredInTheSchema() throws {
        let tool = try XCTUnwrap(ReminderTools.all.first { $0.name == "reminders_bulk_update" })
        let properties = try XCTUnwrap(tool.inputSchema.object("properties"))
        for field in ReminderTools.bulkUpdateFields {
            XCTAssertNotNil(properties[field], "settable field `\(field)` is not in the schema, so "
                            + "no caller can discover it")
        }
    }
}

final class ListOpsTests: XCTestCase {

    func testRenameAndMergeAreOfferedAndDocumented() throws {
        let lists = try XCTUnwrap(ReminderTools.all.first { $0.name == "reminders_lists" })
        let properties = try XCTUnwrap(lists.inputSchema.object("properties"))
        let action = try XCTUnwrap(properties["action"] as? JSONObject)
        let actions = Set(action["enum"] as? [String] ?? [])
        XCTAssertEqual(actions, ["list", "create", "rename", "merge", "delete"])
        for key in ["from", "into", "confirmMerge"] {
            XCTAssertNotNil(properties[key], "merge argument `\(key)` is not in the schema")
        }
    }
}

final class VagueTitleTests: XCTestCase {

    private func reminder(title: String, notes: String? = nil, due: Bool = false) -> EKReminder {
        let r = EKReminder(eventStore: EKEventStore())
        r.title = title
        r.notes = notes
        if due { r.dueDateComponents = DateComponents(year: 2026, month: 12, day: 1) }
        return r
    }

    /// Quantities whose object was never written down: "3 boxes" of what?
    func testBareQuantityIsFlagged() {
        XCTAssertNotNil(ReminderTools.vagueReason(reminder(title: "3 boxes")))
        XCTAssertNotNil(ReminderTools.vagueReason(reminder(title: "12 large for the party")))
    }

    func testShortTitleWithNoContextIsFlagged() {
        XCTAssertNotNil(ReminderTools.vagueReason(reminder(title: "Milk")))
    }

    /// Conservative on purpose. A false positive teaches you to ignore the flag,
    /// so any channel carrying meaning clears it.
    func testNotesOrDueDateClearTheFlag() {
        XCTAssertNil(ReminderTools.vagueReason(
            reminder(title: "Milk", notes: "for Saturday's recipe")))
        XCTAssertNil(ReminderTools.vagueReason(reminder(title: "Milk", due: true)))
    }

    func testOrdinaryTitleIsNotFlagged() {
        XCTAssertNil(ReminderTools.vagueReason(reminder(title: "Renew passport before March")))
    }
}
