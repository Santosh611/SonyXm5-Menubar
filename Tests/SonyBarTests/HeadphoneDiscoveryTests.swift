import XCTest
@testable import SonyBar

final class HeadphoneDiscoveryTests: XCTestCase {
    typealias Candidate = HeadphoneDiscovery.Candidate

    func testRenamedHeadphonesAreSelectedByService() {
        for name in ["Nadeem's Sony XM5", "My headphones", ""] {
            let headset = Candidate(id: "AA-BB", name: name, connected: true, hasControlService: true)
            XCTAssertEqual(HeadphoneDiscovery.select(from: [headset], preferredAddress: nil)?.id, headset.id)
        }
    }

    func testModelNameDoesNotMakeUnrelatedDeviceCompatible() {
        let other = Candidate(id: "11-22", name: "WH-1000XM5", connected: true, hasControlService: false)
        XCTAssertNil(HeadphoneDiscovery.select(from: [other], preferredAddress: nil))
    }

    func testExplicitOfflineSelectionWinsOverConnectedHeadphones() {
        let connected = Candidate(id: "11-22", name: "Sony", connected: true, hasControlService: true)
        let saved = Candidate(id: "AA-BB", name: "Renamed", connected: false, hasControlService: false)
        XCTAssertEqual(HeadphoneDiscovery.select(from: [connected, saved], preferredAddress: "aa:bb")?.id, saved.id)
    }

    func testMissingSavedDeviceDoesNotSilentlySwitchHeadphones() {
        let other = Candidate(id: "11-22", name: "Sony", connected: true, hasControlService: true)
        XCTAssertNil(HeadphoneDiscovery.select(from: [other], preferredAddress: "AA-BB"))
    }
}
