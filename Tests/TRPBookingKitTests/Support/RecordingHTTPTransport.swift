import Foundation
@testable import TRPBookingKit

/// A transport that answers a fixed response and keeps every request it was sent, so a test can
/// inspect the url and headers an authorizer produced.
final class RecordingHTTPTransport: HTTPTransport, @unchecked Sendable {

    var statusCode = 200
    var body = Data()
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}
