import XCTest
@testable import TRPBookingKit

final class TRPBookingTests: XCTestCase {

    private let registry = BookingProviderRegistry([1: .toristy, 2: .viator, 3: .victory])

    private func makeToristy() -> ToristyCredentials {
        ToristyCredentials(apiKey: "key", baseURL: URL(string: "https://toristy.example.com")!)
    }

    private func makeViator() -> ViatorCredentials {
        ViatorCredentials(apiKey: "key", environment: .sandbox,
                          paymentPageURL: URL(string: "https://host.example.com/pay")!, subChannelId: "sub")
    }

    private func makeVictory() -> VictoryCredentials {
        VictoryCredentials(token: "tok", secret: "sekret", environment: .sandbox)
    }

    // MARK: - activity(for:) routing

    func testActivityRoutesToristyToServiceId() throws {
        let configuration = BookingConfiguration(registry: registry, toristy: makeToristy())
        let booking = TRPBooking(configuration: configuration, store: InMemoryBookingRecordStore(),
                                 toristyPayment: MockPaymentProcessing())

        let activity = try booking.activity(for: "C_123_1")

        XCTAssertEqual(activity, .toristy(serviceId: 123))
    }

    func testActivityRoutesViatorToProductCode() throws {
        let configuration = BookingConfiguration(registry: registry, viator: makeViator())
        let booking = TRPBooking(configuration: configuration, store: InMemoryBookingRecordStore())

        let activity = try booking.activity(for: "C_ABC123_2")

        XCTAssertEqual(activity, .viator(productCode: "ABC123"))
    }

    func testActivityRoutesVictoryToEventId() throws {
        let configuration = BookingConfiguration(registry: registry, victory: makeVictory())
        let booking = TRPBooking(configuration: configuration, store: InMemoryBookingRecordStore())

        let activity = try booking.activity(for: "C_456_3")

        XCTAssertEqual(activity, .victory(eventId: 456))
    }

    // MARK: - invalidActivityId

    func testActivityThrowsInvalidActivityIdForAMalformedId() {
        let configuration = BookingConfiguration(registry: registry)
        let booking = TRPBooking(configuration: configuration, store: InMemoryBookingRecordStore())

        XCTAssertThrowsError(try booking.activity(for: "not-a-valid-id")) { error in
            guard case BookingError.invalidActivityId = error else { return XCTFail("Expected invalidActivityId, got \(error)") }
        }
    }

    func testActivityThrowsInvalidActivityIdWhenToristyProductIdIsNotAnInt() {
        let configuration = BookingConfiguration(registry: registry, toristy: makeToristy())
        let booking = TRPBooking(configuration: configuration, store: InMemoryBookingRecordStore(),
                                 toristyPayment: MockPaymentProcessing())

        XCTAssertThrowsError(try booking.activity(for: "C_ABC_1")) { error in
            guard case BookingError.invalidActivityId = error else { return XCTFail("Expected invalidActivityId, got \(error)") }
        }
    }

    func testActivityThrowsInvalidActivityIdWhenVictoryProductIdIsNotAnInt() {
        let configuration = BookingConfiguration(registry: registry, victory: makeVictory())
        let booking = TRPBooking(configuration: configuration, store: InMemoryBookingRecordStore())

        XCTAssertThrowsError(try booking.activity(for: "C_ABC_3")) { error in
            guard case BookingError.invalidActivityId = error else { return XCTFail("Expected invalidActivityId, got \(error)") }
        }
    }

    // MARK: - unsupportedProvider / providerNotConfigured

    func testActivityThrowsUnsupportedProviderWhenTheRegistryHasNoMapping() {
        let configuration = BookingConfiguration(registry: registry)
        let booking = TRPBooking(configuration: configuration, store: InMemoryBookingRecordStore())

        XCTAssertThrowsError(try booking.activity(for: "C_1_99")) { error in
            guard case BookingError.unsupportedProvider(let providerId) = error else { return XCTFail("Expected unsupportedProvider, got \(error)") }
            XCTAssertEqual(providerId, 99)
        }
    }

    func testActivityThrowsProviderNotConfiguredWhenTheMappedProviderHasNoCredentials() {
        let configuration = BookingConfiguration(registry: registry)
        let booking = TRPBooking(configuration: configuration, store: InMemoryBookingRecordStore())

        XCTAssertThrowsError(try booking.activity(for: "C_1_3")) { error in
            guard case BookingError.providerNotConfigured(let kind) = error else { return XCTFail("Expected providerNotConfigured, got \(error)") }
            XCTAssertEqual(kind, .victory)
        }
    }

    // MARK: - canBook

    func testCanBookIsTrueForARoutableIdAndFalseOtherwise() {
        let configuration = BookingConfiguration(registry: registry, victory: makeVictory())
        let booking = TRPBooking(configuration: configuration, store: InMemoryBookingRecordStore())

        XCTAssertTrue(booking.canBook(activityId: "C_1_3"))
        XCTAssertFalse(booking.canBook(activityId: "C_1_2"))
        XCTAssertFalse(booking.canBook(activityId: "not-a-valid-id"))
    }

    // MARK: - isAvailable / checkout wiring

    func testToristyCheckoutIsBuiltOnlyWhenBothCredentialsAndPaymentAreSupplied() {
        let withCredentialsOnly = TRPBooking(
            configuration: BookingConfiguration(registry: registry, toristy: makeToristy()),
            store: InMemoryBookingRecordStore()
        )
        XCTAssertNil(withCredentialsOnly.toristy)
        XCTAssertFalse(withCredentialsOnly.isAvailable(.toristy))

        let withPaymentOnly = TRPBooking(
            configuration: BookingConfiguration(registry: registry),
            store: InMemoryBookingRecordStore(),
            toristyPayment: MockPaymentProcessing()
        )
        XCTAssertNil(withPaymentOnly.toristy)
        XCTAssertFalse(withPaymentOnly.isAvailable(.toristy))

        let withBoth = TRPBooking(
            configuration: BookingConfiguration(registry: registry, toristy: makeToristy()),
            store: InMemoryBookingRecordStore(),
            toristyPayment: MockPaymentProcessing()
        )
        XCTAssertNotNil(withBoth.toristy)
        XCTAssertTrue(withBoth.isAvailable(.toristy))
    }

    func testViatorCheckoutIsBuiltWheneverCredentialsArePresent() {
        let booking = TRPBooking(configuration: BookingConfiguration(registry: registry, viator: makeViator()),
                                 store: InMemoryBookingRecordStore())

        XCTAssertNotNil(booking.viator)
        XCTAssertTrue(booking.isAvailable(.viator))
    }

    func testVictoryCheckoutIsBuiltWheneverCredentialsArePresent() {
        let booking = TRPBooking(configuration: BookingConfiguration(registry: registry, victory: makeVictory()),
                                 store: InMemoryBookingRecordStore())

        XCTAssertNotNil(booking.victory)
        XCTAssertTrue(booking.isAvailable(.victory))
    }

    // MARK: - store delegation

    func testResolveUnfinishedAndRecordsDelegateToTheSharedStore() async throws {
        let store = InMemoryBookingRecordStore()
        let record = BookingRecord(reference: BookingReference(provider: .victory, primary: "ref-1"),
                                   activityId: "C_1_3", title: "Show", travelDate: nil,
                                   status: .charged, total: nil, currency: nil, deadline: nil,
                                   receipt: nil, providerStatus: nil, createdAt: Date())
        await store.save(record)
        let booking = TRPBooking(configuration: BookingConfiguration(registry: registry), store: store)

        let recorded = await booking.records()
        XCTAssertEqual(recorded.map(\.id), [record.id])

        let resolved = await booking.resolveUnfinished()
        XCTAssertEqual(resolved.map(\.id), [record.id])
    }
}
