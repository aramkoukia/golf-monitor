import XCTest
@testable import GolfMonitor

final class SmokeTests: XCTestCase {
    func testClubSpinTableIsPositive() {
        for club in Club.allCases { XCTAssertGreaterThan(club.typicalSpinRpm, 0) }
    }
}
