import CoreLocation
import EventKit
import Foundation
import MapKit

/// A place a reminder can fire at.
struct Place: Equatable {
    var title: String
    var latitude: Double
    var longitude: Double
    var radius: Double = LocationAlarms.defaultRadius
    var address: String?

    var json: JSONObject {
        var out: JSONObject = ["title": title, "latitude": latitude, "longitude": longitude, "radius": radius]
        if let address, !address.isEmpty { out["address"] = address }
        return out
    }
}

// MARK: - Location alarms ("when I arrive at / leave a place")

/// `{"location": ..., "proximity": "arrive"|"leave"}` alarms for reminders.
///
/// EventKit carries these as an `EKAlarm` with a `structuredLocation` and a
/// `proximity`. The reminder syncs over iCloud and the PHONE does the
/// geofencing, so this host needs no Location Services grant: all it does is
/// turn a place into coordinates and store them.
///
/// Everything here except `Places.search` is pure, so the parsing rules are
/// testable with no TCC grant and no network.
enum LocationAlarms {
    /// Metres. Reminders on iOS treats roughly 100 m as its smallest useful fence.
    static let defaultRadius: Double = 100
    static let maxRadius: Double = 100_000

    static let locationFields: Set<String> = ["title", "latitude", "longitude", "radius"]

    /// Turns place text into one place, or throws. Injected so tests never search.
    typealias Resolver = (String) throws -> Place

    static func proximity(from entry: JSONObject, at index: Int) throws -> EKAlarmProximity {
        guard let raw = entry["proximity"] else { return .enter }
        switch (raw as? String)?.lowercased() {
        case "arrive", "arriving", "enter": return .enter
        case "leave", "leaving", "depart": return .leave
        default:
            throw ToolError("alarm[\(index)]: proximity must be \"arrive\" or \"leave\".")
        }
    }

    /// `location` is either place text (resolved by `resolve`) or an object with
    /// coordinates, which is used exactly as given.
    static func place(from entry: JSONObject, at index: Int, resolve: Resolver) throws -> Place {
        if let text = entry["location"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ToolError("alarm[\(index)]: location is empty.") }
            return try resolve(trimmed)
        }
        guard let obj = entry["location"] as? JSONObject else {
            throw ToolError("alarm[\(index)]: location must be place text or "
                + "{title, latitude, longitude, radius?}.")
        }
        let unknown = obj.keys.filter { !locationFields.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw ToolError("alarm[\(index)]: unknown location field(s) \(unknown.joined(separator: ", ")). "
                + "Accepted: \(locationFields.sorted().joined(separator: ", ")).")
        }
        guard let latitude = obj.double("latitude"), let longitude = obj.double("longitude") else {
            throw ToolError("alarm[\(index)]: a location object needs numeric `latitude` and `longitude` "
                + "(or pass the place as text to have it looked up).")
        }
        guard (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else {
            throw ToolError("alarm[\(index)]: latitude must be -90...90 and longitude -180...180.")
        }
        var radius = defaultRadius
        if obj["radius"] != nil {
            guard let r = obj.double("radius"), r > 0, r <= maxRadius else {
                throw ToolError("alarm[\(index)]: radius is in metres and must be between 1 and \(Int(maxRadius)).")
            }
            radius = r
        }
        let title = obj.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Place(title: title.isEmpty ? "Pinned location" : title,
                     latitude: latitude, longitude: longitude, radius: radius)
    }

    static func alarm(at place: Place, proximity: EKAlarmProximity) -> EKAlarm {
        let location = EKStructuredLocation(title: place.title)
        location.geoLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
        location.radius = place.radius
        let alarm = EKAlarm()
        alarm.structuredLocation = location
        alarm.proximity = proximity
        return alarm
    }

    /// nil when the alarm is an ordinary time alarm.
    static func json(_ alarm: EKAlarm) -> JSONObject? {
        guard let location = alarm.structuredLocation else { return nil }
        var place: JSONObject = ["title": location.title ?? ""]
        if let geo = location.geoLocation {
            place["latitude"] = geo.coordinate.latitude
            place["longitude"] = geo.coordinate.longitude
        }
        place["radius"] = location.radius > 0 ? location.radius : defaultRadius
        let proximity: String
        switch alarm.proximity {
        case .enter: proximity = "arrive"
        case .leave: proximity = "leave"
        default: proximity = "none"
        }
        return ["location": place, "proximity": proximity]
    }

    /// Identity for add/remove matching; nil for a time alarm. Coordinates are
    /// rounded to about a metre so a round trip through iCloud still matches.
    static func signature(_ alarm: EKAlarm) -> String? {
        guard let location = alarm.structuredLocation else { return nil }
        let c = location.geoLocation?.coordinate
        return String(format: "loc:%d:%.5f,%.5f", alarm.proximity.rawValue, c?.latitude ?? 0, c?.longitude ?? 0)
    }
}

// MARK: - Turning place text into coordinates

enum Places {
    /// Saved places: `{"home": {"title": "Home", "latitude": .., "longitude": .., "radius": 150}}`.
    /// Personal, so it lives beside policy.json, never in the repo.
    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["HOMEPORT_PLACES"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/homeport/places.json")
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// A missing file is an empty list. A malformed one is an error: silently
    /// ignoring it would send "home" to a map search and pin somebody else's.
    static func saved(at url: URL = fileURL) throws -> [String: Place] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            throw ToolError("places.json is not a JSON object of name -> {title, latitude, longitude, radius?}.")
        }
        var out: [String: Place] = [:]
        for (name, value) in root {
            guard let obj = value as? JSONObject else {
                throw ToolError("places.json: \"\(name)\" must be {title?, latitude, longitude, radius?}.")
            }
            var entry: JSONObject = ["location": obj]
            if obj["title"] == nil { entry["location"] = obj.merging(["title": name]) { a, _ in a } }
            do {
                out[normalize(name)] = try LocationAlarms.place(from: entry, at: 0) { _ in
                    throw ToolError("unreachable")
                }
            } catch let error as ToolError {
                throw ToolError("places.json: \"\(name)\": "
                    + error.message.replacingOccurrences(of: "alarm[0]: ", with: ""))
            }
        }
        return out
    }

    /// Choose one place from search results, or refuse.
    ///
    /// A reminder that fires at the wrong building is worse than an error, so
    /// this only accepts a single result, or a single result whose name IS the
    /// query. Anything else returns the candidates for the caller to choose
    /// from and retry with coordinates.
    static func pick(query: String, candidates: [Place]) throws -> Place {
        if candidates.isEmpty {
            throw ToolError("No place found for \"\(query)\". Add a city, or pass "
                + "location as {title, latitude, longitude}.")
        }
        if candidates.count == 1 { return candidates[0] }
        let wanted = normalize(query)
        let exact = candidates.filter { normalize($0.title) == wanted }
        if exact.count == 1 { return exact[0] }
        let shown = candidates.prefix(5).map { c -> String in
            let address = (c.address.map { " (\($0))" }) ?? ""
            return String(format: "{\"title\": \"%@\", \"latitude\": %.6f, \"longitude\": %.6f}%@",
                          c.title, c.latitude, c.longitude, address)
        }
        throw ToolError("\"\(query)\" matches \(candidates.count) places, so nothing was set. "
            + "Retry with one of these as `location`: " + shown.joined(separator: "; "))
    }

    static func resolve(_ text: String) throws -> Place {
        if let hit = try saved()[normalize(text)] { return hit }
        return labelled(try pick(query: text, candidates: try search(text)))
    }

    /// A searched place is titled with its address. Search is biased to where
    /// the host is and a lone result is accepted, so the name alone ("Eiffel
    /// Tower") cannot tell the caller, or the person reading the reminder on
    /// the phone, which one was pinned. EKStructuredLocation has no address
    /// field of its own, so the title is the only place it can travel.
    static func labelled(_ place: Place) -> Place {
        guard let address = place.address?.replacingOccurrences(of: "\n", with: ", "),
              !address.isEmpty, !address.contains(place.title) else {
            var out = place
            if let address = place.address, address.contains(place.title) {
                out.title = address.replacingOccurrences(of: "\n", with: ", ")
            }
            return out
        }
        var out = place
        out.title = "\(place.title), \(address)"
        return out
    }

    /// Apple's place search. Needs the network but no Location Services grant.
    ///
    /// MapKit cannot run inside the HTTP daemon. `MKLocalSearch` hops to the
    /// main QUEUE and initialises `NSApplication` there; the daemon's main
    /// thread is parked in `dispatchMain()`, so that block lands on a worker
    /// thread, AppKit's init never returns, and because the caller holds
    /// `BridgeQueue.eventKit` every client hangs with it (`cancel` blocks too, so a
    /// timeout does not save it).
    ///
    /// So off the main thread the search runs in a short-lived child: this
    /// same binary with `--place-search`, which has an ordinary main run loop
    /// and is killed if it overruns. On the main thread (stdio, tests, and the
    /// child itself) it runs in-process.
    static func search(_ text: String, timeout: TimeInterval = 10) throws -> [Place] {
        Thread.isMainThread ? try searchInProcess(text, timeout: timeout)
                            : try searchInChild(text, timeout: timeout)
    }

    static let searchFlag = "--place-search"

    /// Entry point for the child. Prints a JSON array of places and exits.
    static func runSearchHelper(arguments: [String]) -> Never {
        guard let at = arguments.firstIndex(of: searchFlag), arguments.count > at + 1 else {
            FileHandle.standardError.write(Data("usage: \(searchFlag) <text>\n".utf8))
            exit(2)
        }
        do {
            let places = try searchInProcess(arguments[at + 1], timeout: 10).map(\.json)
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: places))
            exit(0)
        } catch {
            let message = (error as? ToolError)?.message ?? "\(error)"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    static func searchInChild(_ text: String, timeout: TimeInterval) throws -> [Place] {
        let failed = "Pass location as {title, latitude, longitude} instead."
        guard let executable = Bundle.main.executablePath else {
            throw ToolError("Place search is unavailable (no executable path). \(failed)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [searchFlag, text]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            throw ToolError("Place search could not start (\(error.localizedDescription)). \(failed)")
        }
        // The child enforces `timeout` itself; the margin here is for a child that is stuck.
        if exited.wait(timeout: .now() + timeout + 5) == .timedOut {
            process.terminate()
            throw ToolError("Place search timed out. Try again, or pass location as {title, latitude, longitude}.")
        }
        // A few places of JSON: far below the pipe buffer, so reading after exit cannot block.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ToolError(message.isEmpty || message.count > 400 ? "Place search failed. \(failed)" : message)
        }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [JSONObject] else {
            throw ToolError("Place search returned something unreadable. \(failed)")
        }
        return rows.compactMap { row in
            guard let latitude = row.double("latitude"), let longitude = row.double("longitude") else { return nil }
            return Place(title: row.string("title") ?? text, latitude: latitude, longitude: longitude,
                         radius: row.double("radius") ?? LocationAlarms.defaultRadius, address: row.string("address"))
        }
    }

    /// Main thread only: spins the run loop, which also drains the main queue
    /// MapKit calls back on.
    static func searchInProcess(_ text: String, timeout: TimeInterval) throws -> [Place] {
        precondition(Thread.isMainThread, "MapKit search must run on the main thread")
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.pointOfInterest, .address]
        let search = MKLocalSearch(request: request)

        var items: [MKMapItem]?
        var failure: Error?
        search.start { response, error in
            items = response?.mapItems ?? []
            failure = error
        }
        let deadline = Date().addingTimeInterval(timeout)
        while items == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let found = items else {
            search.cancel()
            throw ToolError("Place search timed out. Try again, or pass location as {title, latitude, longitude}.")
        }
        if let failure {
            if (failure as? MKError)?.code == .placemarkNotFound { return [] }
            throw ToolError("Place search failed (\(failure.localizedDescription)). "
                + "Pass location as {title, latitude, longitude} instead.")
        }
        return found.map { place(from: $0, fallbackTitle: text) }
    }

    private static func place(from item: MKMapItem, fallbackTitle: String) -> Place {
        let coordinate: CLLocationCoordinate2D
        let address: String?
        if #available(macOS 26.0, *) {
            coordinate = item.location.coordinate
            address = item.address?.fullAddress
        } else {
            coordinate = item.placemark.coordinate
            address = item.placemark.title
        }
        return Place(title: item.name ?? fallbackTitle,
                     latitude: coordinate.latitude, longitude: coordinate.longitude,
                     address: address)
    }
}
