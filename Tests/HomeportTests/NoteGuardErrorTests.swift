import XCTest
@testable import Homeport

/// Errors are the path the result filter cannot see, so the scrubbing decision
/// gets its own coverage. Pure: no policy file, no Notes.app.
final class NoteGuardErrorTests: XCTestCase {

    private let blocked = ["Private"]
    private func scrub(_ tool: String, _ args: JSONObject, _ message: String,
                       protected: Set<String> = []) -> String {
        NoteGuard.scrubError(tool: tool, args: args, message: message,
                             blockedFolders: blocked,
                             isProtectedId: { protected.contains($0) })
    }

    func testErrorNamingABlockedFolderIsWithheld() {
        // The original leak: an untargeted query whose error lists folder names.
        let out = scrub("notes_query", [:], "No folder named Foo. Folders: Ideas, Private, Work")
        XCTAssertEqual(out, NoteGuard.withheldError)
    }

    func testErrorForACallTargetingABlockedFolderIsWithheld() {
        let out = scrub("notes_append", ["folder": "Private", "title": "x"],
                        "Can't get note \"Something revealing\"")
        XCTAssertEqual(out, NoteGuard.withheldError)
    }

    func testErrorForAProtectedNoteIdIsWithheld() {
        XCTAssertEqual(scrub("notes_read", ["id": "n1"], "Can't get note \"Secret\"", protected: ["n1"]),
                       NoteGuard.withheldError)
        XCTAssertEqual(scrub("notes_append", ["noteId": "n1"], "timed out", protected: ["n1"]),
                       NoteGuard.withheldError)
    }

    /// A policy refusal must still be recognisable as one.
    func testWithheldErrorStillSaysReadBlocked() {
        XCTAssertTrue(NoteGuard.withheldError.contains("read-blocked"))
    }

    func testUnrelatedNotesErrorPassesThrough() {
        let message = "No folder named Foo."
        XCTAssertEqual(scrub("notes_query", ["folder": "Foo"], message), message)
        XCTAssertEqual(scrub("notes_read", ["id": "n2"], message, protected: ["n1"]), message)
    }

    /// Only Notes-touching tools are scrubbed; a calendar error that happens to
    /// contain the word is not about a note.
    func testNonNotesToolsAreUntouched() {
        let message = "Calendar Private not found"
        XCTAssertEqual(scrub("calendar_query", ["calendar": "Private"], message), message)
    }

    func testSummarizeIntoABlockedFolderIsScrubbed() {
        XCTAssertEqual(scrub("voicememos_summarize", ["id": "r1", "folder": "Private"], "boom"),
                       NoteGuard.withheldError)
    }

    func testNoBlockedFoldersMeansNoScrubbing() {
        let message = "Folders: Private"
        XCTAssertEqual(NoteGuard.scrubError(tool: "notes_query", args: [:], message: message,
                                            blockedFolders: [], isProtectedId: { _ in true }),
                       message)
    }
}
