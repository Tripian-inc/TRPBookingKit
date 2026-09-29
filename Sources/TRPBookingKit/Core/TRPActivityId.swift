import Foundation

/// A tour-api activity id, `C_{productId}_{providerId}[_{cityId}]`.
///
/// Three parts carry no city; four or more read the last two as provider and city, so a
/// product id that itself contains underscores survives the round trip.
public struct TRPActivityId: Hashable, Sendable, CustomStringConvertible {

    public static let defaultPrefix = "C"

    public let prefix: String
    public let productId: String
    public let providerId: Int
    public let cityId: Int?

    public init(productId: String, providerId: Int, cityId: Int? = nil, prefix: String = TRPActivityId.defaultPrefix) {
        self.prefix = prefix
        self.productId = productId
        self.providerId = providerId
        self.cityId = cityId
    }

    /// Parses a raw activity id; `nil` when it does not follow the tour-api format.
    public init?(_ rawValue: String) {
        let parts = rawValue.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let prefix = parts.first, !prefix.isEmpty else { return nil }

        let productParts: ArraySlice<String>
        let providerId: Int
        let cityId: Int?
        if parts.count == 3 {
            guard let provider = Int(parts[2]) else { return nil }
            productParts = parts[1..<2]
            providerId = provider
            cityId = nil
        } else {
            guard let provider = Int(parts[parts.count - 2]), let city = Int(parts[parts.count - 1]) else { return nil }
            productParts = parts[1..<(parts.count - 2)]
            providerId = provider
            cityId = city
        }

        let productId = productParts.joined(separator: "_")
        guard !productId.isEmpty else { return nil }
        self.init(productId: productId, providerId: providerId, cityId: cityId, prefix: prefix)
    }

    public var rawValue: String {
        var parts = [prefix, productId, String(providerId)]
        if let cityId { parts.append(String(cityId)) }
        return parts.joined(separator: "_")
    }

    public var description: String { rawValue }
}
