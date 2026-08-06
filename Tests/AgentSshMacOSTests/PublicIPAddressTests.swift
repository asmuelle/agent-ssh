import XCTest
@testable import AgentSshMacOS

final class PublicIPAddressTests: XCTestCase {
    func testAllowsPublicAddresses() {
        XCTAssertTrue(PublicIPAddress.isEligibleForExternalGeolocation("8.8.8.8"))
        XCTAssertTrue(PublicIPAddress.isEligibleForExternalGeolocation("1.1.1.1"))
        XCTAssertTrue(PublicIPAddress.isEligibleForExternalGeolocation("2606:4700:4700::1111"))
    }

    func testRejectsPrivateLoopbackLinkLocalAndReservedAddresses() {
        let addresses = [
            "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1",
            "172.16.0.1", "192.168.1.1", "192.0.2.1", "198.18.0.1",
            "192.88.99.1",
            "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255",
            "::", "::1", "fc00::1", "fe80::1", "ff02::1", "2001:db8::1",
            "::8.8.8.8", "2001::1", "2001:2::1", "2001:10::1",
        ]

        for address in addresses {
            XCTAssertFalse(
                PublicIPAddress.isEligibleForExternalGeolocation(address),
                "Expected \(address) to remain local"
            )
        }
    }

    func testRejectsHostnamesAndMalformedInput() {
        XCTAssertFalse(PublicIPAddress.isEligibleForExternalGeolocation("server.example.com"))
        XCTAssertFalse(PublicIPAddress.isEligibleForExternalGeolocation("not-an-ip"))
        XCTAssertFalse(PublicIPAddress.isEligibleForExternalGeolocation(""))
    }
}
