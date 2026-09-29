import Foundation

/// A client-side total shown while the customer fills the form.
///
/// Only an estimate: the amount charged is always `totalPrice` from `bookingValidation`.
public struct ToristyPriceEstimate: Sendable, Hashable {
    public let passengers: Decimal
    public let extras: Decimal
    public let pickup: Decimal
    public let dropoff: Decimal
    public let currency: String?

    public var total: Decimal { passengers + extras + pickup + dropoff }
}

/// Computes `ToristyPriceEstimate`s from a rate's prices.
public struct ToristyPriceEstimator: Sendable {

    public init() {}

    public func estimate(_ selection: ToristySelection, information: ToristyBookingInformation) -> ToristyPriceEstimate? {
        guard let rate = information.rate(id: selection.rateId) else { return nil }
        let partySize = selection.passengers.count
        let departureRate = selection.startTime.rate(id: rate.id)
        let perBooking = selection.startTime.pricePer == .booking || departureRate?.pricedPerPerson == false

        let passengerTotal: Decimal
        if perBooking {
            passengerTotal = rate.prices.compactMap { $0.unitPrice(forPartySize: partySize) }.min() ?? 0
        } else {
            passengerTotal = selection.passengers.reduce(Decimal(0)) { total, passenger in
                total + (rate.category(id: passenger.pricingCategoryId)?.unitPrice(forPartySize: partySize) ?? 0)
            }
        }

        let extrasTotal = selection.passengers.flatMap(\.extras).reduce(Decimal(0)) { total, chosen in
            guard let extra = rate.extras.first(where: { $0.id == chosen.extraId }) else { return total }
            return total + extra.price * Decimal(chosen.quantity)
        }

        return ToristyPriceEstimate(
            passengers: passengerTotal,
            extras: extrasTotal,
            pickup: selection.pickup == nil ? 0 : transferTotal(rate.pickup, selection: selection),
            dropoff: selection.dropoff == nil ? 0 : transferTotal(rate.dropoff, selection: selection),
            currency: information.currency ?? selection.currency
        )
    }

    private func transferTotal(_ pricing: ToristyTransferPricing?, selection: ToristySelection) -> Decimal {
        guard let pricing, !pricing.prices.isEmpty else { return 0 }
        if pricing.pricePer == .booking {
            return pricing.prices.map(\.price).min() ?? 0
        }
        var total = Decimal(0)
        for passenger in selection.passengers {
            total += transferPrice(pricing, categoryId: passenger.pricingCategoryId)
        }
        return total
    }

    private func transferPrice(_ pricing: ToristyTransferPricing, categoryId: String) -> Decimal {
        let matching = pricing.prices.first { $0.pricingCategoryId == categoryId }
        let fallback = pricing.prices.first { $0.pricingCategoryId == nil }
        return (matching ?? fallback)?.price ?? 0
    }
}
