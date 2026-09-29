import Foundation

/// Sends a prepared request; swapped for a stub in tests, or for a Tripian backend proxy later.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The default transport, over `URLSession`.
public struct URLSessionHTTPTransport: HTTPTransport {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: BookingError.transport(error.localizedDescription))
                    return
                }
                guard let response = response as? HTTPURLResponse else {
                    continuation.resume(throwing: BookingError.transport("No HTTP response."))
                    return
                }
                continuation.resume(returning: (data ?? Data(), response))
            }
            task.resume()
        }
    }
}

/// Adds a provider's credentials to a request just before it is sent.
public protocol RequestAuthorizing: Sendable {
    func authorize(_ request: inout URLRequest) throws
}
