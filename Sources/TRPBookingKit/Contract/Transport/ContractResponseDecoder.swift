import Foundation

/// Turns a contract response into its payload, or into the `ContractError` it carries.
enum ContractResponseDecoder {

    /// The envelope of `body`; a response with `success: false` or a 4xx/5xx status is thrown as `ContractError`.
    static func envelope<Payload: Codable & Sendable>(
        _ type: Payload.Type, httpStatus: Int, body: Data
    ) throws -> BookingContract.Envelope<Payload> {
        let decoder = JSONDecoder()
        if httpStatus >= 400 || isFailure(body, decoder: decoder) {
            let envelope = try decode(BookingContract.Envelope<BookingContract.ErrorData>.self, httpStatus: httpStatus,
                                      body: body, decoder: decoder)
            guard let data = envelope.data else { throw BookingContract.CheckoutClientError.missingData(httpStatus: httpStatus) }
            throw BookingContract.ContractError(httpStatus: httpStatus, data: data)
        }
        return try decode(BookingContract.Envelope<Payload>.self, httpStatus: httpStatus, body: body, decoder: decoder)
    }

    /// The payload of `body`, which must be present.
    static func payload<Payload: Codable & Sendable>(_ type: Payload.Type, httpStatus: Int, body: Data) throws -> Payload {
        guard let data = try envelope(type, httpStatus: httpStatus, body: body).data else {
            throw BookingContract.CheckoutClientError.missingData(httpStatus: httpStatus)
        }
        return data
    }

    /// A `CheckoutResponse` from a checkout call's status, headers and body.
    static func checkoutResponse(httpStatus: Int, headers: [String: String],
                                 body: Data) throws -> BookingContract.CheckoutResponse {
        let checkout = try payload(BookingContract.Checkout.self, httpStatus: httpStatus, body: body)
        return BookingContract.CheckoutResponse(checkout: checkout, httpStatus: httpStatus,
                                                retryAfter: retryAfter(in: headers))
    }

    /// The `Retry-After` header in seconds, matched without regard to case.
    static func retryAfter(in headers: [String: String]) -> TimeInterval? {
        headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }
            .flatMap { TimeInterval($0.value.trimmingCharacters(in: .whitespaces)) }
    }

    private struct SuccessFlag: Decodable {
        let success: Bool?
    }

    private static func isFailure(_ body: Data, decoder: JSONDecoder) -> Bool {
        (try? decoder.decode(SuccessFlag.self, from: body))?.success == false
    }

    private static func decode<T: Decodable>(_ type: T.Type, httpStatus: Int, body: Data,
                                             decoder: JSONDecoder) throws -> T {
        do {
            return try decoder.decode(T.self, from: body)
        } catch {
            throw BookingContract.CheckoutClientError.undecodable(httpStatus: httpStatus, reason: String(describing: error))
        }
    }
}
