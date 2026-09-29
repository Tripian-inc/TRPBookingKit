import XCTest
@testable import TRPBookingKit

/// Covers how Toristy's payment status text maps onto the booking record.
final class ToristyPaymentStatusTests: XCTestCase {

    func testSpellingsOfTheSameStatusAgree() {
        for raw in ["timedOut", "TIMED OUT", "timed_out", "Timed-Out"] {
            XCTAssertEqual(ToristyPaymentStatus(raw), .timedOut, raw)
        }
        XCTAssertEqual(ToristyPaymentStatus("Canceled"), .cancelled)
        XCTAssertEqual(ToristyPaymentStatus("CONFIRMED"), .confirmed)
    }

    func testAnUnknownStatusKeepsItsText() {
        XCTAssertEqual(ToristyPaymentStatus("On Hold"), .other("On Hold"))
        XCTAssertNil(ToristyPaymentStatus("On Hold").recordStatus)
    }

    func testRecordStatuses() {
        XCTAssertEqual(ToristyPaymentStatus.reserved.recordStatus, .held)
        XCTAssertEqual(ToristyPaymentStatus.timedOut.recordStatus, .expired)
    }
}
