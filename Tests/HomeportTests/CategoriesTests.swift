import XCTest
@testable import Homeport

/// The binary ships machinery, the operator ships the taxonomy, and a stock
/// build knows nothing about anyone.
final class CategoriesTests: XCTestCase {

    func testNoCategoriesAreCompiledIn() {
        // On a machine with no config, the shipped binary must know nothing
        // about what a recording might be.
        if Categories.all.isEmpty {
            XCTAssertEqual(Categories.names, ["unknown"])
        } else {
            // A developer with a local config: every category must come from
            // it, plus the built-in fallback and nothing else.
            XCTAssertEqual(Categories.names, Categories.all.map(\.name) + ["unknown"])
        }
    }

    func testClassificationIsUnknownWithoutConfig() throws {
        guard Categories.all.isEmpty else {
            throw XCTSkip("a local categories.json is present; this asserts the empty case")
        }
        let (category, confidence, reason) = RecordingClassifier.fromMetadata(
            date: Date(), duration: 3600, isQuickTimeAudio: false)
        XCTAssertEqual(category, .unknown)
        XCTAssertEqual(confidence, 0.0)
        XCTAssertTrue(reason.contains("no categories configured"))
    }

    func testContentScoringNeedsAVocabulary() throws {
        guard Categories.all.isEmpty else {
            throw XCTSkip("a local categories.json is present; this asserts the empty case")
        }
        let text = String(repeating: "agenda standup roadmap deliverable ", count: 100)
        XCTAssertNil(RecordingClassifier.fromContent(text),
                     "with no configured lexicons there is nothing to score against")
    }

    func testUnknownIsTreatedAsConfidential() {
        // If we could not tell what a recording is, its text must not leave.
        XCTAssertNil(Categories.definition(for: .unknown),
                     "unknown has no definition, so callers fall back to confidential")
    }

    func testParseRejectsUnconfiguredNames() {
        XCTAssertNil(Categories.parse("not-a-configured-name"), "a name with no definition is not a category")
        XCTAssertNil(Categories.parse(nil))
        XCTAssertEqual(Categories.parse("unknown"), .unknown)
    }

    func testShippedExampleConfigParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("deploy/categories.example.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cats = try XCTUnwrap(root["categories"] as? [[String: Any]])
        XCTAssertFalse(cats.isEmpty)
        for c in cats {
            XCTAssertNotNil(c["name"] as? String)
            XCTAssertNotNil(c["extractionPrompt"] as? String)
        }
    }
}
