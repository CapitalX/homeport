import XCTest
@testable import Homeport

/// Tagged tailnet devices reach the bridge through `tailscale serve` with no
/// user identity headers. These pin how such requests resolve, and that the
/// "did not come through serve" rejection still holds.
final class TailnetIdentityTests: XCTestCase {

    func testUserOwnedDeviceKeepsItsLogin() {
        let caller = TailnetIdentity.resolve(userLogin: "you@github", forwardedFor: "100.64.0.10")
        XCTAssertEqual(caller?.userLogin, "you@github")
        XCTAssertEqual(caller?.address, "100.64.0.10")
        XCTAssertEqual(caller?.label, "you@github")
    }

    func testTaggedDeviceResolvesWithoutALogin() {
        let caller = TailnetIdentity.resolve(userLogin: nil, forwardedFor: "100.64.0.20")
        XCTAssertNotNil(caller)
        XCTAssertNil(caller?.userLogin)
        XCTAssertEqual(caller?.label, "tagged device")
    }

    func testEmptyLoginIsTreatedAsTagged() {
        let caller = TailnetIdentity.resolve(userLogin: "", forwardedFor: "100.64.0.20")
        XCTAssertNotNil(caller)
        XCTAssertNil(caller?.userLogin)
    }

    func testRequestWithoutForwardedForIsRejected() {
        // No X-Forwarded-For means the request did not arrive through serve.
        XCTAssertNil(TailnetIdentity.resolve(userLogin: "you@github", forwardedFor: nil))
        XCTAssertNil(TailnetIdentity.resolve(userLogin: nil, forwardedFor: nil))
        XCTAssertNil(TailnetIdentity.resolve(userLogin: nil, forwardedFor: ""))
    }

    func testFirstForwardedAddressIsTheOrigin() {
        let caller = TailnetIdentity.resolve(userLogin: nil, forwardedFor: "100.64.0.30, 127.0.0.1")
        XCTAssertEqual(caller?.address, "100.64.0.30")
    }
}
