import Foundation
import CryptoKit

/// Signs Ticket Evolution requests: `X-Token` plus `X-Signature = base64(HMAC-SHA256(string, secret))`.
///
/// The string is `"GET {host}{path}?{sorted query}"` for a GET and `"{METHOD} {host}{path}?{body}"`
/// otherwise. The query is re-sorted in the url too, so what is signed is exactly what is sent.
/// TE's own guidance keeps the secret on a backend; a host that signs on the device accepts that
/// the secret ships in the app.
public struct VictoryRequestSigner: RequestAuthorizing {

    private let token: String
    private let key: SymmetricKey

    public init(token: String, secret: String) {
        self.token = token
        key = SymmetricKey(data: Data(secret.utf8))
    }

    public func authorize(_ request: inout URLRequest) throws {
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw BookingError.transport("Cannot sign a request without a url.")
        }
        if let items = components.percentEncodedQueryItems, !items.isEmpty {
            components.percentEncodedQueryItems = items.sorted { Self.pair($0) < Self.pair($1) }
            request.url = components.url
        }
        let signed = try Self.signatureString(for: request)
        request.setValue(token, forHTTPHeaderField: "X-Token")
        request.setValue(signature(of: signed), forHTTPHeaderField: "X-Signature")
    }

    /// The string TE expects to be signed; exposed so it can be checked against TE's generator.
    public static func signatureString(for request: URLRequest) throws -> String {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else {
            throw BookingError.transport("Cannot sign a request without a host.")
        }
        let method = (request.httpMethod ?? "GET").uppercased()
        let target = host + components.percentEncodedPath
        guard method != "GET" else {
            let query = (components.percentEncodedQueryItems ?? []).map(pair).sorted().joined(separator: "&")
            return "GET \(target)?\(query)"
        }
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return "\(method) \(target)?\(body)"
    }

    public func signature(of string: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(string.utf8), using: key)).base64EncodedString()
    }

    private static func pair(_ item: URLQueryItem) -> String {
        item.value.map { "\(item.name)=\($0)" } ?? item.name
    }
}
