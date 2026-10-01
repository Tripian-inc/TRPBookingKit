import Foundation

/// A `BookingClient` over the bookings the local checkout saved in `BookingRecordStore`.
///
/// Bookings live on the device only, the status comes from the record, and cancelling a
/// Ticket Evolution order always answers `NOT_CANCELLABLE`. An unknown uuid answers `404` with the code `NOT_FOUND`.
public struct LocalBookingClient: BookingClient {
    public typealias BC = BookingContract

    private let store: BookingRecordStore
    private let viator: ViatorCheckout?
    private let toristy: ToristyCheckout?
    private let contractVersion: String
    private let now: @Sendable () -> Date

    public init(store: BookingRecordStore, viator: ViatorCheckout?, toristy: ToristyCheckout?,
                contractVersion: String = BookingContract.version, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.viator = viator
        self.toristy = toristy
        self.contractVersion = contractVersion
        self.now = now
    }

    public func list(status: [BC.BookingStatus], page: Int, limit: Int, lang: String) async throws -> BC.BookingPage {
        try checkVersion()
        let bookings = await store.all().compactMap(Self.booking).filter { status.isEmpty || status.contains($0.status.value) }
        let perPage = max(limit, 1)
        let current = max(page, 1)
        let slice = Array(bookings.dropFirst((current - 1) * perPage).prefix(perPage))
        let totalPages = max(1, (bookings.count + perPage - 1) / perPage)
        let pagination = BC.Pagination(count: slice.count, total: bookings.count, perPage: perPage, currentPage: current,
                                       totalPages: totalPages, links: BC.Pagination.Links(next: nil, previous: nil))
        return BC.BookingPage(bookings: slice, pagination: pagination)
    }

    public func get(uuid: String, lang: String) async throws -> BC.Booking {
        try checkVersion()
        return try await Self.booking(try record(uuid)).orThrow(Self.notFound)
    }

    public func cancel(uuid: String, reason: String?, lang: String, idempotencyKey: BC.IdempotencyKey) async throws -> BC.Booking {
        try checkVersion()
        let record = try await record(uuid)
        guard let booking = record.contractBooking, booking.cancellation.allowed else { throw Self.notCancellable }
        do {
            switch record.reference.provider {
            case .viator:
                guard let viator else { throw Self.notCancellable }
                _ = try await viator.cancel(record.reference)
            case .toristy:
                guard let toristy else { throw Self.notCancellable }
                _ = try await toristy.cancel(record.reference, note: reason, notify: true)
            case .victory:
                throw Self.notCancellable
            }
        } catch let error as BC.ContractError {
            throw error
        } catch BookingError.notCancellable {
            throw Self.notCancellable
        } catch {
            throw BC.ContractError(httpStatus: 503, data: BC.ErrorData(code: .init(.supplierUnavailable), errors: [],
                                                                       retryable: true, checkout: nil))
        }
        let cancelled = booking.cancelled()
        await store.update(record.reference) {
            $0.status = .cancelled
            $0.contractBooking = cancelled
        }
        return cancelled
    }

    private static let notFound = BC.ContractError(httpStatus: 404, data: BC.ErrorData(
        code: .init(rawValue: "NOT_FOUND"), errors: [], retryable: false, checkout: nil))

    private static let notCancellable = BC.ContractError(httpStatus: 409, data: BC.ErrorData(
        code: .init(.notCancellable), errors: [], retryable: false, checkout: nil))

    private func checkVersion() throws {
        guard contractVersion != BC.version else { return }
        throw BC.ContractError(httpStatus: 400, data: BC.ErrorData(
            code: .init(.versionUnsupported), errors: [], retryable: false, checkout: nil, supported: [BC.version]))
    }

    private func record(_ uuid: String) async throws -> BookingRecord {
        guard let record = await store.all().first(where: { $0.contractBooking?.uuid == uuid }) else { throw Self.notFound }
        return record
    }

    private static func booking(_ record: BookingRecord) -> BC.Booking? {
        record.contractBooking.map { $0.with(status: record.status.contractStatus) }
    }
}

extension BookingContract.Booking {
    /// A copy with another status, vouchers, cancellation or refund.
    func with(status: BookingContract.BookingStatus? = nil, vouchers: [Voucher]? = nil,
              cancellation: Cancellation? = nil, refund: Refund?? = nil) -> BookingContract.Booking {
        BookingContract.Booking(uuid: uuid, status: status.map { .init($0) } ?? self.status, provider: provider,
                                providerReference: providerReference, product: product, units: units, start: start,
                                durationMinutes: durationMinutes, meetingPoint: meetingPoint, amount: amount,
                                utcExpiresAt: utcExpiresAt, vouchers: vouchers ?? self.vouchers,
                                cancellation: cancellation ?? self.cancellation, refund: refund ?? self.refund, contact: contact)
    }

    /// The booking after a cancellation the supplier accepted: no vouchers, and the refund on its way.
    func cancelled() -> BookingContract.Booking {
        let policyAmount = cancellation.refundAmount
        return with(status: .cancelled, vouchers: [],
                    cancellation: Cancellation(allowed: false, deadline: nil, refund: cancellation.refund, refundAmount: policyAmount),
                    refund: .some(policyAmount.map { Refund(status: .init(.pending), amount: $0) }))
    }
}

private extension Optional {
    func orThrow(_ error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}
