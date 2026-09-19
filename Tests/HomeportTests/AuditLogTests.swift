import XCTest
@testable import Homeport

/// The audit log exists to answer "who did what to which record". These pin the
/// half that matters most: it must never become a second copy of the content.
final class AuditLogTests: XCTestCase {

    func testSendDetailRecordsRecipientAndSizeButNeverTheBody() {
        let secret = "meet me at the usual place at nine"
        let d = AuditLog.detail(tool: "messages_send",
                                args: ["to": "+1 (555) 123-4567",
                                       "body": secret,
                                       "confirmSend": true])
        XCTAssertEqual(d["to"] as? String, "+15551234567", "handle should be normalized")
        XCTAssertEqual(d["bodyChars"] as? Int, secret.count)
        XCTAssertEqual(d["confirmed"] as? Bool, true)

        let dumped = String(describing: d)
        XCTAssertFalse(dumped.contains(secret), "message body must never reach the audit log")
        XCTAssertNil(d["body"])
    }

    func testContactUpdateDetailNamesTheEditedFieldsNotTheValues() {
        let d = AuditLog.detail(tool: "contacts_update",
                                args: ["id": "ABC-123",
                                       "removePhones": ["+15551110000"],
                                       "addPhones": [["label": "mobile", "value": "+15559998888"]]])
        XCTAssertEqual(d["contact"] as? String, "ABC-123")
        XCTAssertEqual(d["edits"] as? [String], ["addPhones", "removePhones"])

        let dumped = String(describing: d)
        XCTAssertFalse(dumped.contains("5559998888"), "the new number is a value, not metadata")
    }

    /// Whole-calendar and whole-list deletion are the largest deletions the
    /// server can make, so whether they were confirmed is part of the record.
    func testCalendarAndListDeletionRecordConfirmation() {
        let cal = AuditLog.detail(tool: "calendar_calendars",
                                  args: ["action": "delete", "calendar": "Old", "confirmDelete": true])
        XCTAssertEqual(cal["action"] as? String, "delete")
        XCTAssertEqual(cal["confirmed"] as? Bool, true)
        let list = AuditLog.detail(tool: "reminders_lists", args: ["action": "delete", "list": "Old"])
        XCTAssertEqual(list["confirmed"] as? Bool, false)
        XCTAssertTrue(AuditLog.detail(tool: "calendar_calendars", args: [:]).isEmpty,
                      "listing calendars is not worth a line")
    }

    func testReadToolsRecordNoDetail() {
        XCTAssertTrue(AuditLog.detail(tool: "notes_read", args: ["id": "x"]).isEmpty)
        XCTAssertTrue(AuditLog.detail(tool: "messages_query", args: ["search": "bank"]).isEmpty,
                      "a search term is user content and must not be logged")
    }

    func testRecordWritesOneParseableJSONLine() throws {
        let before = (try? String(contentsOf: AuditLog.url, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        AuditLog.record(tool: "bridge_ping", caller: "unit-test", transport: "stdio",
                        outcome: "ok", ms: 1)
        let lines = try String(contentsOf: AuditLog.url, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, before + 1)

        let obj = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["tool"] as? String, "bridge_ping")
        XCTAssertEqual(obj?["caller"] as? String, "unit-test")
        XCTAssertEqual(obj?["outcome"] as? String, "ok")
        XCTAssertNotNil(obj?["ts"])
    }

    func testStdioCallsAreAttributedRatherThanDropped() {
        AuditLog.record(tool: "notes_read", caller: nil, transport: "stdio", outcome: "ok", ms: 2)
        let last = (try? String(contentsOf: AuditLog.url, encoding: .utf8))?
            .split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertTrue(last.contains("\"caller\":\"local\""),
                      "an unidentified stdio caller is 'local', never absent")
    }
}
