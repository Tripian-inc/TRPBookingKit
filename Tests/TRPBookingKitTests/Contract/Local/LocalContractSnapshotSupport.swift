import Foundation
import XCTest
@testable import TRPBookingKit

/// Removes fixture paths the local clients cannot produce, written as `a.b[0].c` or `a.b[*].c`;
/// a trailing `[N]` removes that element.
enum SnapshotExclusions {
    static func strip(_ paths: [String], from json: CanonicalJSON) -> CanonicalJSON {
        paths.reduce(json) { remove(tokens(of: $1)[...], from: $0) }
    }

    private enum Token { case key(String), index(Int), any }

    private static func tokens(of path: String) -> [Token] {
        path.split(separator: ".").flatMap { part -> [Token] in
            let pieces = part.split(separator: "[", omittingEmptySubsequences: false).map(String.init)
            var result: [Token] = pieces[0].isEmpty ? [] : [.key(pieces[0])]
            for piece in pieces.dropFirst() {
                let inner = piece.dropLast()
                result.append(inner == "*" ? .any : .index(Int(inner) ?? -1))
            }
            return result
        }
    }

    private static func remove(_ tokens: ArraySlice<Token>, from json: CanonicalJSON) -> CanonicalJSON {
        guard let first = tokens.first else { return json }
        let rest = tokens.dropFirst()
        switch (first, json) {
        case let (.key(key), .object(object)):
            var copy = object
            if rest.isEmpty { copy[key] = nil } else if let child = object[key] { copy[key] = remove(rest, from: child) }
            return .object(copy)
        case let (.index(index), .array(array)) where array.indices.contains(index):
            var copy = array
            if rest.isEmpty { copy.remove(at: index) } else { copy[index] = remove(rest, from: array[index]) }
            return .array(copy)
        case let (.any, .array(array)):
            return rest.isEmpty ? .array([]) : .array(array.map { remove(rest, from: $0) })
        default:
            return json
        }
    }
}

/// Sends a fixture request through the local clients and compares the answer with the fixture.
func assertLocalSnapshot(_ directory: String, _ name: String, checkout: CheckoutClient, bookings: BookingClient,
                         excluding excluded: [String] = [], file: StaticString = #filePath, line: UInt = #line) async throws {
    let exchange = try ContractFixtures.exchange(directory, name)
    let encoder = JSONEncoder()
    let produced: Data
    var status = 200
    var retryAfter: String?
    do {
        switch try await performContractRequest(exchange.request, checkout: checkout, bookings: bookings) {
        case .checkout(let response):
            produced = try encoder.encode(response.checkout)
            status = response.httpStatus
            retryAfter = response.retryAfter.map { String(Int($0)) }
        case .booking(let booking):
            produced = try encoder.encode(booking)
        case .page(let page):
            produced = try encoder.encode(page.bookings)
        }
    } catch let error as BookingContract.ContractError {
        produced = try encoder.encode(error.data)
        status = error.httpStatus
    }
    XCTAssertEqual(status, exchange.response.status, "\(directory)/\(name) status", file: file, line: line)
    XCTAssertEqual(retryAfter, exchange.response.headers["Retry-After"], "\(directory)/\(name) Retry-After", file: file, line: line)
    let expectedValue = try XCTUnwrap(exchange.response.body.objectValue?["data"], file: file, line: line)
    let expected = SnapshotExclusions.strip(excluded, from: try CanonicalJSON(data: encoder.encode(expectedValue)))
    let actual = SnapshotExclusions.strip(excluded, from: try CanonicalJSON(data: produced))
    if let difference = actual.firstDifference(from: expected) {
        XCTFail("\(directory)/\(name): \(difference)", file: file, line: line)
    }
}
