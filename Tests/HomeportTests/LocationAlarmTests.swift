import EventKit
import XCTest
@testable import Homeport

/// Location alarms ("when I arrive at / leave a place") and the stricter alarm
/// parsing that came with them.
///
/// Pure apart from the one opt-in live search at the bottom: no EventKit store,
/// so no TCC grant and nothing created. Coordinates are public landmarks only.
final class LocationAlarmTests: XCTestCase {

    private let landmark = Place(title: "Test Landmark", latitude: 48.8584, longitude: 2.2945)

    private func noSearch(_ text: String) throws -> Place {
        XCTFail("resolver should not be called for \(text)")
        return landmark
    }

    private func message(_ body: () throws -> Void) -> String {
        do { try body() } catch let e as ToolError { return e.message } catch { return "\(error)" }
        return ""
    }

    // MARK: - Parsing

    func testCoordinatesAreUsedAsGivenWithDefaults() throws {
        let alarms = try Alarms.build(
            from: [["location": ["title": "Tower", "latitude": 48.8584, "longitude": 2.2945]]],
            allowLocation: true, resolve: noSearch)
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms[0].proximity, .enter, "arrive is the default")
        XCTAssertEqual(alarms[0].structuredLocation?.title, "Tower")
        XCTAssertEqual(alarms[0].structuredLocation?.radius, LocationAlarms.defaultRadius)
        XCTAssertEqual(alarms[0].structuredLocation?.geoLocation?.coordinate.latitude ?? 0, 48.8584, accuracy: 1e-6)
    }

    func testTextIsResolvedAndLeaveIsHonoured() throws {
        var asked: [String] = []
        let alarms = try Alarms.build(
            from: [["location": "  test landmark ", "proximity": "leave"]],
            allowLocation: true) { text in asked.append(text); return self.landmark }
        XCTAssertEqual(asked, ["test landmark"])
        XCTAssertEqual(alarms[0].proximity, .leave)
        XCTAssertEqual(alarms[0].structuredLocation?.title, "Test Landmark")
    }

    func testRadiusIsCarried() throws {
        let alarms = try Alarms.build(
            from: [["location": ["latitude": 1, "longitude": 2, "radius": 250]]],
            allowLocation: true, resolve: noSearch)
        XCTAssertEqual(alarms[0].structuredLocation?.radius, 250)
    }

    func testBadInputIsRejectedNotDropped() {
        let cases: [(JSONObject, String)] = [
            (["location": "x", "proximity": "near"], "proximity"),
            (["location": ["latitude": 1]], "longitude"),
            (["location": ["latitude": 100, "longitude": 2]], "latitude"),
            (["location": ["latitude": 1, "longitude": 2, "radius": 0]], "radius"),
            (["location": ["latitude": 1, "longitude": 2, "name": "x"]], "name"),
            (["location": ["latitude": 1, "longitude": 2], "offset": 5], "offset"),
            (["location": ["latitude": 1, "longitude": 2], "relativeOffset": -60], "only one"),
            (["relativeOffset": -60, "proximity": "arrive"], "proximity"),
            (["relativeOffset": "soon"], "relativeOffset"),
            (["absoluteDate": "not a date"], "absoluteDate"),
            ([:], "relativeOffset")
        ]
        for (entry, expected) in cases {
            let text = message { _ = try Alarms.build(from: [entry], allowLocation: true) { _ in self.landmark } }
            XCTAssertTrue(text.contains(expected), "\(entry) -> \(text)")
        }
    }

    func testErrorNamesTheIndex() {
        let text = message {
            _ = try Alarms.build(from: [["relativeOffset": -60], ["when": "later"]], allowLocation: true, resolve: noSearch)
        }
        XCTAssertTrue(text.contains("alarm[1]"), text)
    }

    func testEventsRefuseLocationAlarms() {
        let text = message {
            _ = try Alarms.build(from: [["location": ["latitude": 1, "longitude": 2]]], resolve: noSearch)
        }
        XCTAssertTrue(text.contains("reminders"), text)
    }

    func testTimeAlarmsStillParse() throws {
        let alarms = try Alarms.build(from: [["relativeOffset": -900], ["absoluteDate": "2030-01-02T09:00:00Z"]])
        XCTAssertEqual(alarms[0].relativeOffset, -900)
        XCTAssertNotNil(alarms[1].absoluteDate)
        XCTAssertNil(alarms[0].structuredLocation)
    }

    // MARK: - Reading back

    func testRoundTripThroughJSON() throws {
        let built = try Alarms.build(
            from: [["location": ["title": "Tower", "latitude": 48.8584, "longitude": 2.2945, "radius": 150],
                    "proximity": "leave"],
                   ["relativeOffset": -600]],
            allowLocation: true, resolve: noSearch)
        let json = Alarms.json(built)
        XCTAssertEqual(json[0].string("proximity"), "leave")
        XCTAssertEqual(json[0].object("location")?.string("title"), "Tower")
        XCTAssertEqual(json[0].object("location")?.double("radius"), 150)
        XCTAssertEqual(json[1].double("relativeOffset"), -600)
        XCTAssertNil(json[1]["location"])

        // What comes out must be accepted back in, or reminders_update cannot round-trip it.
        let again = try Alarms.build(from: json, allowLocation: true, resolve: noSearch)
        XCTAssertEqual(again.map(AlarmEdits.signature), built.map(AlarmEdits.signature))
    }

    func testSignatureSeparatesPlaceAndDirection() {
        let here = LocationAlarms.alarm(at: landmark, proximity: .enter)
        let leaving = LocationAlarms.alarm(at: landmark, proximity: .leave)
        let elsewhere = LocationAlarms.alarm(at: Place(title: "x", latitude: 1, longitude: 2), proximity: .enter)
        let timed = EKAlarm(relativeOffset: 0)
        let all = [here, leaving, elsewhere, timed].map(AlarmEdits.signature)
        XCTAssertEqual(Set(all).count, 4, "\(all)")
        XCTAssertEqual(AlarmEdits.signature(here),
                       AlarmEdits.signature(LocationAlarms.alarm(at: landmark, proximity: .enter)))
    }

    // MARK: - Choosing among search results

    func testPickRefusesToGuess() {
        let a = Place(title: "Coffee Shop", latitude: 1, longitude: 1, address: "1 First St")
        let b = Place(title: "Coffee Shop", latitude: 2, longitude: 2, address: "2 Second St")
        let text = message { _ = try Places.pick(query: "coffee shop", candidates: [a, b]) }
        XCTAssertTrue(text.contains("matches 2 places"), text)
        XCTAssertTrue(text.contains("1 First St") && text.contains("latitude"), text)

        let none = message { _ = try Places.pick(query: "nowhere", candidates: []) }
        XCTAssertTrue(none.contains("No place found"), none)
    }

    func testPickAcceptsASingleOrExactlyNamedResult() throws {
        let a = Place(title: "Test Landmark", latitude: 1, longitude: 1)
        let b = Place(title: "Test Landmark Gift Shop", latitude: 2, longitude: 2)
        XCTAssertEqual(try Places.pick(query: "anything", candidates: [b]), b)
        XCTAssertEqual(try Places.pick(query: "test landmark", candidates: [b, a]), a)
    }

    func testSearchedPlaceCarriesItsAddress() {
        let bare = Place(title: "Test Landmark", latitude: 1, longitude: 1)
        let withAddress = Place(title: "Test Landmark", latitude: 1, longitude: 1, address: "1 First St, Springfield")
        let repeated = Place(title: "1 First St", latitude: 1, longitude: 1, address: "1 First St, Springfield")
        XCTAssertEqual(Places.labelled(bare).title, "Test Landmark")
        XCTAssertEqual(Places.labelled(withAddress).title, "Test Landmark, 1 First St, Springfield")
        XCTAssertEqual(Places.labelled(repeated).title, "1 First St, Springfield")
    }

    // MARK: - Saved places

    private func writePlaces(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("places-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSavedPlacesLoadAndMatchLoosely() throws {
        let url = try writePlaces(#"{"The Office": {"latitude": 10, "longitude": 20, "radius": 200}}"#)
        let saved = try Places.saved(at: url)
        let hit = try XCTUnwrap(saved[Places.normalize("the office")])
        XCTAssertEqual(hit.title, "The Office")
        XCTAssertEqual(hit.radius, 200)
    }

    func testMissingFileIsEmptyAndMalformedIsAnError() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).json")
        XCTAssertTrue(try Places.saved(at: missing).isEmpty)
        let bad = try writePlaces(#"{"home": {"latitude": 10}}"#)
        let text = message { _ = try Places.saved(at: bad) }
        XCTAssertTrue(text.contains("home") && text.contains("longitude"), text)
    }

    // MARK: - Drift

    /// The tool text is the only place a model learns the shape from.
    func testDescriptionsMentionLocationAlarms() throws {
        for name in ["reminders_create", "reminders_update"] {
            let tool = try XCTUnwrap(ReminderTools.all.first { $0.name == name })
            XCTAssertTrue(tool.description.contains("proximity"), name)
        }
    }

    /// The daemon path must never reach MapKit in-process: it would hang every client.
    func testSearchOffTheMainThreadUsesTheChildAndReturns() {
        let done = expectation(description: "searched")
        var text = ""
        DispatchQueue.global().async {
            // Under XCTest the executable is the test runner, not the bridge, so the
            // child cannot answer. What matters is that the call came back with an error.
            do { _ = try Places.search("anywhere", timeout: 5) } catch {
                text = (error as? ToolError)?.message ?? "\(error)"
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertFalse(text.isEmpty)
    }

    // MARK: - Live (opt-in: needs the network)

    func testLiveSearchFindsALandmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOMEPORT_LIVE_GEOCODE"] == "1",
                          "set HOMEPORT_LIVE_GEOCODE=1 to run")
        // The country matters: results are biased to where the host is, so without
        // it a host near a replica gets the replica, alone. That is why a searched
        // place carries its address in the title (see `Places.resolve`).
        let results = try Places.search("Eiffel Tower, Paris, France")
        XCTAssertTrue(results.contains { abs($0.latitude - 48.858) < 0.01 && abs($0.longitude - 2.294) < 0.01 },
                      "\(results.map { ($0.title, $0.latitude, $0.longitude) })")
    }
}
