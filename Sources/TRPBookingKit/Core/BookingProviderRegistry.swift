import Foundation

/// The providers whose checkout the kit knows how to run.
public enum BookingProviderKind: String, Sendable, CaseIterable, Codable {
    case viator
    case toristy
    case victory
}

/// Maps tour-api numeric provider ids to the checkout that fulfils them.
///
/// The ids are Tripian's to assign, so the host supplies them rather than the kit guessing.
public struct BookingProviderRegistry: Sendable, Equatable {

    public let kindsById: [Int: BookingProviderKind]

    public init(_ kindsById: [Int: BookingProviderKind]) {
        self.kindsById = kindsById
    }

    public func kind(forProviderId providerId: Int) -> BookingProviderKind? {
        kindsById[providerId]
    }

    public func providerId(for kind: BookingProviderKind) -> Int? {
        kindsById.first { $0.value == kind }?.key
    }
}
