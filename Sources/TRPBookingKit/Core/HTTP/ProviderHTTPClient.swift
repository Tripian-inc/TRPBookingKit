import Foundation

/// A JSON client for one provider's API: builds the url, authorizes, sends, and maps errors.
public struct ProviderHTTPClient: Sendable {

    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    /// Turns a non-2xx body into the provider's own error.
    public typealias ErrorParser = @Sendable (_ status: Int, _ body: Data) -> BookingError

    public let baseURL: URL
    public let transport: HTTPTransport
    public let authorizer: RequestAuthorizing?
    public let defaultHeaders: [String: String]
    public let timeout: TimeInterval
    private let errorParser: ErrorParser

    public init(baseURL: URL,
                transport: HTTPTransport = URLSessionHTTPTransport(),
                authorizer: RequestAuthorizing? = nil,
                defaultHeaders: [String: String] = [:],
                timeout: TimeInterval = 30,
                errorParser: @escaping ErrorParser = ProviderHTTPClient.genericError) {
        self.baseURL = baseURL
        self.transport = transport
        self.authorizer = authorizer
        self.defaultHeaders = defaultHeaders
        self.timeout = timeout
        self.errorParser = errorParser
    }

    public func request<Response: Decodable>(_ method: Method,
                                             _ path: String,
                                             query: [URLQueryItem] = [],
                                             headers: [String: String] = [:],
                                             body: Encodable? = nil,
                                             as type: Response.Type = Response.self) async throws -> Response {
        let data = try await send(method, path, query: query, headers: headers, body: body)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BookingError.decoding(String(describing: error))
        }
    }

    /// Sends the call and returns the raw body of a 2xx answer.
    @discardableResult
    public func send(_ method: Method,
                     _ path: String,
                     query: [URLQueryItem] = [],
                     headers: [String: String] = [:],
                     body: Encodable? = nil) async throws -> Data {
        var request = try makeRequest(method, path, query: query, headers: headers, body: body)
        try authorizer?.authorize(&request)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw errorParser(response.statusCode, data)
        }
        return data
    }

    func makeRequest(_ method: Method,
                     _ path: String,
                     query: [URLQueryItem],
                     headers: [String: String],
                     body: Encodable?) throws -> URLRequest {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(url: baseURL.appendingPathComponent(trimmedPath), resolvingAgainstBaseURL: false) else {
            throw BookingError.transport("Invalid path \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw BookingError.transport("Invalid path \(path)") }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        defaultHeaders.merging(headers) { $1 }.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }
        return request
    }

    /// Reads `message`/`error`/`code`-style bodies; used when a provider has no parser of its own.
    public static let genericError: ErrorParser = { status, body in
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = object?["message"] as? String ?? object?["error"] as? String
        let code = object?["code"].map { "\($0)" } ?? object?["errorcode"].map { "\($0)" }
        return .server(status: status, code: code, message: message)
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// Sends a fixed header with every request, the way Viator takes its key.
public struct HeaderKeyAuthorizer: RequestAuthorizing {

    public let headerName: String
    private let value: String

    public init(headerName: String, value: String) {
        self.headerName = headerName
        self.value = value
    }

    public func authorize(_ request: inout URLRequest) throws {
        request.setValue(value, forHTTPHeaderField: headerName)
    }
}

/// Appends a fixed query parameter to every request's url, keeping the query items already there; Toristy takes its
/// key this way and rejects it in a header.
public struct QueryKeyAuthorizer: RequestAuthorizing {

    public let parameterName: String
    private let value: String

    public init(parameterName: String, value: String) {
        self.parameterName = parameterName
        self.value = value
    }

    public func authorize(_ request: inout URLRequest) throws {
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw BookingError.transport("Invalid url \(request.url?.absoluteString ?? "")")
        }
        var items = (components.percentEncodedQueryItems ?? []).filter { $0.name != Self.encode(parameterName) }
        items.append(URLQueryItem(name: Self.encode(parameterName), value: Self.encode(value)))
        components.percentEncodedQueryItems = items
        guard let authorized = components.url else {
            throw BookingError.transport("Invalid url \(url.absoluteString)")
        }
        request.url = authorized
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }
}
