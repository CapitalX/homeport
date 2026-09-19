import XCTest
@testable import Homeport

final class ShortcutsToolsTests: XCTestCase {

    // MARK: - Share-link parsing

    func testAcceptsShareURLAndBareID() {
        let id = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(ShortcutsTools.recordID(from: "https://www.icloud.com/shortcuts/\(id)"), id)
        XCTAssertEqual(ShortcutsTools.recordID(from: id), id)
        XCTAssertEqual(ShortcutsTools.recordID(from: "  https://icloud.com/shortcuts/\(id)?x=1  "), id)
    }

    func testUppercaseIDIsNormalized() {
        XCTAssertEqual(ShortcutsTools.recordID(from: "0123456789ABCDEF0123456789ABCDEF"),
                       "0123456789abcdef0123456789abcdef")
    }

    /// The surrounding URL text is itself full of hex characters ("c", "d",
    /// "f"...). A looser scan would splice a run out of the path and fetch a
    /// real but unrelated shortcut.
    func testRejectsWrongLengthRuns() {
        XCTAssertNil(ShortcutsTools.recordID(from: "https://www.icloud.com/shortcuts/"))
        XCTAssertNil(ShortcutsTools.recordID(from: "abc123"))
        // 31 and 33 characters: near-misses must fail, not truncate to 32.
        XCTAssertNil(ShortcutsTools.recordID(from: String(repeating: "a", count: 31)))
        XCTAssertNil(ShortcutsTools.recordID(from: String(repeating: "a", count: 33)))
    }

    // MARK: - Asset host pinning

    func testDownloadURLFillsFilenameSlot() {
        let asset: JSONObject = [
            "downloadURL": "https://cvws.icloud-content.com/B/abc/${f}?o=token"
        ]
        let url = ShortcutsTools.downloadURL(asset, as: "shortcut.plist")
        XCTAssertEqual(url?.absoluteString,
                       "https://cvws.icloud-content.com/B/abc/shortcut.plist?o=token")
    }

    /// These URLs arrive inside a record from a PUBLIC CloudKit scope. If a
    /// hostile host ever appeared in one, an unpinned fetch would turn
    /// "read this share link" into a request the caller chose.
    func testRejectsNonAppleHostsAndPlainHTTP() {
        for raw in ["https://evil.example.com/${f}",
                    "http://cvws.icloud-content.com/${f}",
                    "https://icloud-content.com.evil.example/${f}",
                    "https://noticloud.com/${f}"] {
            XCTAssertNil(ShortcutsTools.downloadURL(["downloadURL": raw], as: "f.plist"),
                         "should have refused \(raw)")
        }
        XCTAssertNotNil(ShortcutsTools.downloadURL(
            ["downloadURL": "https://www.icloud.com/${f}"], as: "f.plist"))
    }

    // MARK: - Action normalization

    func testAcceptsFriendlyShape() throws {
        let action = try ShortcutsTools.normalizeAction(
            ["identifier": "is.workflow.actions.gettext",
             "parameters": ["WFTextActionText": "hi"]] as JSONObject, at: 0)
        XCTAssertEqual(action.string("WFWorkflowActionIdentifier"), "is.workflow.actions.gettext")
        XCTAssertEqual(action.object("WFWorkflowActionParameters")?.string("WFTextActionText"), "hi")
    }

    /// shortcuts_fetch returns raw WF-prefixed actions; feeding one straight
    /// back into shortcuts_build is the whole remix workflow, so both shapes
    /// must round-trip without the caller rewriting keys.
    func testAcceptsRawFetchedShape() throws {
        let action = try ShortcutsTools.normalizeAction(
            ["WFWorkflowActionIdentifier": "is.workflow.actions.comment",
             "WFWorkflowActionParameters": ["WFCommentActionText": "note"]] as JSONObject, at: 0)
        XCTAssertEqual(action.string("WFWorkflowActionIdentifier"), "is.workflow.actions.comment")
        XCTAssertEqual(action.object("WFWorkflowActionParameters")?.string("WFCommentActionText"),
                       "note")
    }

    func testMissingIdentifierNamesTheOffendingIndex() {
        XCTAssertThrowsError(try ShortcutsTools.normalizeAction(["parameters": [:]] as JSONObject,
                                                               at: 3)) { error in
            let message = (error as? ToolError)?.message ?? ""
            XCTAssertTrue(message.contains("actions[3]"), "unhelpful message: \(message)")
        }
    }

    func testActionParametersDefaultToEmptyRatherThanMissing() throws {
        let action = try ShortcutsTools.normalizeAction(
            ["identifier": "is.workflow.actions.nothing"] as JSONObject, at: 0)
        XCTAssertNotNil(action["WFWorkflowActionParameters"],
                        "WorkflowKit expects the key to exist even when empty")
    }

    // MARK: - Filenames

    func testSlugIsSafeForAFilename() {
        XCTAssertEqual(ShortcutsTools.slug("Turn Off Lights"), "turn-off-lights")
        XCTAssertEqual(ShortcutsTools.slug("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(ShortcutsTools.slug("   "), "shortcut")
        XCTAssertFalse(ShortcutsTools.slug(String(repeating: "x", count: 200)).count > 64)
    }

    /// The signed file's NAME is the shortcut's name in the library -- verified
    /// by importing one identical pair of signed bytes under two filenames. So
    /// this must preserve what the author typed, or every published shortcut
    /// arrives wearing a lowercase slug.
    func testFileNameKeepsTheAuthorsSpacesAndCapitals() {
        XCTAssertEqual(ShortcutsTools.fileName("Bridge Import Test"), "Bridge Import Test")
        XCTAssertEqual(ShortcutsTools.fileName("Daily Summary (v2)"), "Daily Summary (v2)")
    }

    func testFileNameCannotEscapeTheOutbox() {
        XCTAssertEqual(ShortcutsTools.fileName("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(ShortcutsTools.fileName("a/b\\c:d"), "a-b-c-d")
        XCTAssertEqual(ShortcutsTools.fileName(".hidden"), "hidden")
        XCTAssertEqual(ShortcutsTools.fileName("   "), "Shortcut")
        XCTAssertEqual(ShortcutsTools.fileName(".."), "Shortcut")
        XCTAssertFalse(ShortcutsTools.fileName("Name\nwith\nnewlines").contains("\n"))
    }

    // MARK: - Plist values JSON cannot carry

    /// Shortcut parameters legitimately hold Data and Date. Both throw in
    /// JSONSerialization, and they would throw at response-encoding time --
    /// after the handler returned -- so the failure would not even name the
    /// tool.
    func testDataAndDateSurviveConversion() {
        let converted = ShortcutsTools.jsonSafe([
            "blob": Data([0xDE, 0xAD]),
            "when": Date(timeIntervalSince1970: 0),
            "nested": ["deep": [Data([0x01])]]
        ] as JSONObject)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(converted))
        let dict = converted as? JSONObject
        XCTAssertEqual(dict?.string("blob"), "base64:3q0=")
        XCTAssertEqual(dict?.string("when"), "1970-01-01T00:00:00Z")
    }

    // MARK: - Registry

    /// Explicit, not inherited from the fail-closed default: building signs a
    /// distributable artifact and running executes arbitrary owner-written code,
    /// so neither may ever drift down to `.read`.
    func testScopesAreExplicitAndCorrect() {
        XCTAssertEqual(Auth.toolScopes["shortcuts_build"], .write)
        XCTAssertEqual(Auth.toolScopes["shortcuts_run"], .write)
        XCTAssertEqual(Auth.toolScopes["shortcuts_list"], .read)
        XCTAssertEqual(Auth.toolScopes["shortcuts_fetch"], .read)
    }

    func testFetchedContentIsFencedAsUntrusted() {
        XCTAssertEqual(Untrusted.trust(forTool: "shortcuts_fetch"), .untrusted)
        XCTAssertEqual(Untrusted.trust(forTool: "shortcuts_list"), .untrusted)
        XCTAssertEqual(Untrusted.trust(forTool: "shortcuts_run"), .untrusted)
    }

    // MARK: - Guards on the run path

    func testRunRefusesWithoutConfirmation() throws {
        let run = try XCTUnwrap(ShortcutsTools.all.first { $0.name == "shortcuts_run" })
        XCTAssertThrowsError(try run.handler(["name": "Turn off lights"])) { error in
            let message = (error as? ToolError)?.message ?? ""
            XCTAssertTrue(message.contains("confirm:true"), "unhelpful message: \(message)")
        }
        XCTAssertThrowsError(try run.handler(["name": "Turn off lights", "confirm": false]))
    }

    func testBuildRejectsAnEmptyActionList() throws {
        let build = try XCTUnwrap(ShortcutsTools.all.first { $0.name == "shortcuts_build" })
        XCTAssertThrowsError(try build.handler(["name": "Empty", "actions": []]))
    }

    func testBuildRejectsAnUnknownSigningMode() throws {
        let build = try XCTUnwrap(ShortcutsTools.all.first { $0.name == "shortcuts_build" })
        XCTAssertThrowsError(try build.handler([
            "name": "Bad Mode",
            "actions": [["identifier": "is.workflow.actions.comment"]],
            "mode": "everyone"
        ])) { error in
            let message = (error as? ToolError)?.message ?? ""
            XCTAssertTrue(message.contains("anyone"), "unhelpful message: \(message)")
        }
    }
}
