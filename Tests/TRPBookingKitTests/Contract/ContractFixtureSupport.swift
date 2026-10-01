import Foundation
import XCTest
@testable import TRPBookingKit

typealias BC = BookingContract

/// The contract fixtures copied by `scripts/sync-contract-fixtures.sh`.
enum ContractFixtures {

    static var root: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Contract")
    }

    /// Every fixture file, as paths relative to `root`, sorted.
    static func allFiles() throws -> [String] {
        let base = root.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(atPath: base)
        var files: [String] = []
        while let path = enumerator?.nextObject() as? String {
            if path.hasSuffix(".json") { files.append(path) }
        }
        return files.sorted()
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relativePath))
    }

    static func object(_ relativePath: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data(relativePath)) as? [String: Any])
    }

    /// The `body` of a fixture file re-serialised on its own, or `nil` when it is JSON null.
    static func body(_ relativePath: String) throws -> Data? {
        let body = try object(relativePath)["body"]
        guard let body, !(body is NSNull) else { return nil }
        return try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
    }

    static func exchanges(in directory: String) throws -> [BC.RecordedExchange] {
        try BC.RecordedExchange.load(from: root.appendingPathComponent(directory))
    }

    static func exchange(_ directory: String, _ name: String) throws -> BC.RecordedExchange {
        try XCTUnwrap(exchanges(in: directory).first { $0.name == name }, "\(directory)/\(name)")
    }
}

/// JSON compared after sorting keys and reading every number as a `Double`.
indirect enum CanonicalJSON: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CanonicalJSON])
    case object([String: CanonicalJSON])

    init(data: Data) throws {
        self.init(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(CanonicalJSON.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(CanonicalJSON.init(any:)))
        default:
            self = .string(String(describing: value))
        }
    }

    /// The JSON path of the first difference from `other`, or `nil` when both are equal.
    func firstDifference(from other: CanonicalJSON, at path: String = "$") -> String? {
        switch (self, other) {
        case let (.object(lhs), .object(rhs)):
            for key in Set(lhs.keys).union(rhs.keys).sorted() {
                guard let left = lhs[key] else { return "\(path).\(key) (missing after round trip)" }
                guard let right = rhs[key] else { return "\(path).\(key) (added by round trip)" }
                if let difference = left.firstDifference(from: right, at: "\(path).\(key)") { return difference }
            }
            return nil
        case let (.array(lhs), .array(rhs)):
            guard lhs.count == rhs.count else { return "\(path) (\(lhs.count) vs \(rhs.count) elements)" }
            for (index, pair) in zip(lhs, rhs).enumerated() {
                if let difference = pair.0.firstDifference(from: pair.1, at: "\(path)[\(index)]") { return difference }
            }
            return nil
        default:
            return self == other ? nil : "\(path) (\(self) vs \(other))"
        }
    }
}

/// What one fixture request yields when sent through the replay clients.
enum ReplayOutcome {
    case checkout(BC.CheckoutResponse)
    case booking(BC.Booking)
    case page(BC.BookingPage)
}

/// Sends `request` through the client the contract assigns its path to, with arguments read from its body.
func performContractRequest(_ request: BC.RecordedRequest, checkout: CheckoutClient, bookings: BookingClient) async throws -> ReplayOutcome {
    let pathAndQuery = request.path.split(separator: "?", maxSplits: 1).map(String.init)
    let segments = pathAndQuery[0].split(separator: "/").map(String.init).dropFirst()
    let query = Dictionary(uniqueKeysWithValues: (pathAndQuery.count > 1 ? pathAndQuery[1] : "")
        .split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        })
    let body = request.body ?? .null
    let lang = query["lang"] ?? body.objectValue?["lang"]?.stringValue ?? "en"
    let key = request.headers["Idempotency-Key"].map(BC.IdempotencyKey.init(rawValue:)) ?? BC.IdempotencyKey()
    let parts = Array(segments)

    switch (request.method, parts.count, parts.first) {
    case ("POST", 1, "checkouts"):
        return .checkout(try await checkout.create(body.decode(as: BC.CreateCheckoutRequest.self), idempotencyKey: key))
    case ("GET", 2, "checkouts"):
        return .checkout(try await checkout.get(id: parts[1], lang: lang))
    case ("POST", 4, "checkouts") where parts[2] == "steps":
        let submit = try body.decode(as: BC.SubmitStepRequest.self)
        return .checkout(try await checkout.submit(checkoutId: parts[1], stepId: parts[3], answers: submit.answers,
                                                   expectedAmount: submit.expectedAmount, lang: submit.lang,
                                                   idempotencyKey: key))
    case ("POST", 3, "checkouts") where parts[2] == "back":
        let back = try body.decode(as: BC.BackRequest.self)
        return .checkout(try await checkout.back(checkoutId: parts[1], fromStepId: back.fromStepId, lang: back.lang,
                                                 idempotencyKey: key))
    case ("POST", 4, "checkouts") where parts[2] == "actions":
        let action = try body.decode(as: BC.ActionResultRequest.self)
        return .checkout(try await checkout.action(checkoutId: parts[1], actionId: parts[3], result: action.result,
                                                   lang: action.lang, idempotencyKey: key))
    case ("POST", 3, "checkouts") where parts[2] == "extend":
        return .checkout(try await checkout.extend(checkoutId: parts[1], lang: lang, idempotencyKey: key))
    case ("POST", 3, "checkouts") where parts[2] == "cancel":
        return .checkout(try await checkout.cancel(checkoutId: parts[1], lang: lang, idempotencyKey: key))
    case ("GET", 1, "bookings"):
        let status = (query["status"] ?? "").split(separator: ",").map { BC.BookingStatus(decoding: String($0)) }
        return .page(try await bookings.list(status: status, page: Int(query["page"] ?? "1") ?? 1,
                                             limit: Int(query["limit"] ?? "20") ?? 20, lang: lang))
    case ("GET", 2, "bookings"):
        return .booking(try await bookings.get(uuid: parts[1], lang: lang))
    case ("POST", 3, "bookings") where parts[2] == "cancel":
        let cancel = try body.decode(as: BC.CancelBookingRequest.self)
        return .booking(try await bookings.cancel(uuid: parts[1], reason: cancel.reason, lang: cancel.lang,
                                                  idempotencyKey: key))
    default:
        throw BC.CheckoutClientError.unexpectedRequest(expected: "a contract call", actual: request.signature)
    }
}
