import XCTest
@testable import Homeport

/// `messages_send` is the only tool that moves data to a third party in one
/// call. Its old guard was a boolean in the caller's own JSON; these cover the
/// replacement.
final class RecipientAllowlistTests: XCTestCase {

    func testPhonePunctuationIsIgnored() {
        let canonical = Auth.normalizeHandle("+15551234567")
        XCTAssertEqual(Auth.normalizeHandle("+1 (555) 123-4567"), canonical)
        XCTAssertEqual(Auth.normalizeHandle("+1-555-123-4567"), canonical)
        XCTAssertEqual(Auth.normalizeHandle("  +15551234567 "), canonical)
    }

    func testLeadingPlusIsPreserved() {
        XCTAssertNotEqual(Auth.normalizeHandle("+15551234567"),
                          Auth.normalizeHandle("15551234567"),
                          "the + is the one piece of punctuation that means something")
    }

    func testEmailIsCaseInsensitive() {
        XCTAssertEqual(Auth.normalizeHandle("Someone@Example.COM"), "someone@example.com")
    }

    func testEmailPunctuationIsNotStripped() {
        XCTAssertEqual(Auth.normalizeHandle("first.last+tag@example.com"),
                       "first.last+tag@example.com",
                       "digit-filtering must not apply to addresses")
    }

    func testEmptyAllowlistMatchesNothing() {
        let empty: Set<String> = []
        XCTAssertFalse(empty.contains(Auth.normalizeHandle("+15551234567")),
                       "an unconfigured list must send nothing, not everything")
    }

    func testEnrolledHandleMatchesRegardlessOfCallerFormatting() {
        let enrolled: Set<String> = [Auth.normalizeHandle("+1 (555) 123-4567")]
        XCTAssertTrue(enrolled.contains(Auth.normalizeHandle("+15551234567")))
    }
}
