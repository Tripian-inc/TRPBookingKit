import XCTest
@testable import TRPBookingKit

final class QueryKeyAuthorizerTests: XCTestCase {

    private func makeRequest(_ url: String) -> URLRequest {
        URLRequest(url: URL(string: url)!)
    }

    private func queryItems(_ request: URLRequest) -> [URLQueryItem] {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    func testAuthorizeAppendsTheParameterToARequestWithNoQuery() throws {
        var request = makeRequest("https://api.toristy.com/bookingInformation/1")
        let authorizer = QueryKeyAuthorizer(parameterName: "apikey", value: "secret-key")

        try authorizer.authorize(&request)

        XCTAssertEqual(queryItems(request), [URLQueryItem(name: "apikey", value: "secret-key")])
    }

    func testAuthorizePreservesExistingQueryItems() throws {
        var request = makeRequest("https://api.toristy.com/bookingConfirmation?cartid=cart1&confirmationCode=conf1")
        let authorizer = QueryKeyAuthorizer(parameterName: "apikey", value: "secret-key")

        try authorizer.authorize(&request)

        XCTAssertEqual(Set(queryItems(request)), Set([
            URLQueryItem(name: "cartid", value: "cart1"),
            URLQueryItem(name: "confirmationCode", value: "conf1"),
            URLQueryItem(name: "apikey", value: "secret-key")
        ]))
    }

    func testAuthorizeReplacesAnExistingItemOfTheSameName() throws {
        var request = makeRequest("https://api.toristy.com/bookingInformation/1?apikey=stale")
        let authorizer = QueryKeyAuthorizer(parameterName: "apikey", value: "fresh")

        try authorizer.authorize(&request)

        XCTAssertEqual(queryItems(request), [URLQueryItem(name: "apikey", value: "fresh")])
    }

    func testAuthorizePercentEncodesReservedCharactersInTheKey() throws {
        var request = makeRequest("https://api.toristy.com/bookingInformation/1")
        let authorizer = QueryKeyAuthorizer(parameterName: "apikey", value: "a+b&c=d")

        try authorizer.authorize(&request)

        let encodedQuery = request.url?.query
        XCTAssertEqual(encodedQuery, "apikey=a%2Bb%26c%3Dd")
        XCTAssertEqual(queryItems(request), [URLQueryItem(name: "apikey", value: "a+b&c=d")])
    }
}
