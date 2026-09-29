import Foundation

/// What the customer picked on the booking form, before it is validated with Toristy.
public struct ToristySelection: Sendable, Hashable {
    public var serviceId: Int
    public var rateId: String
    public var date: BookingDate
    public var startTime: ToristyStartTime
    public var mainContact: [ToristyAnswer]
    public var passengers: [ToristyPassenger]
    public var bookingAnswers: [ToristyAnswer]
    public var pickup: ToristyTransferSelection?
    public var dropoff: ToristyTransferSelection?
    public var currency: String

    public init(serviceId: Int, rateId: String, date: BookingDate, startTime: ToristyStartTime, mainContact: [ToristyAnswer],
                passengers: [ToristyPassenger], bookingAnswers: [ToristyAnswer] = [], pickup: ToristyTransferSelection? = nil,
                dropoff: ToristyTransferSelection? = nil, currency: String) {
        self.serviceId = serviceId
        self.rateId = rateId
        self.date = date
        self.startTime = startTime
        self.mainContact = mainContact
        self.passengers = passengers
        self.bookingAnswers = bookingAnswers
        self.pickup = pickup
        self.dropoff = dropoff
        self.currency = currency
    }

    /// `"YYYY-MM-DD HH:MM"`, exactly the chosen start time.
    public var validationDate: String {
        "\(date.description) \(startTime.time.prefix(5))"
    }

    /// How many passengers of each pricing category are booked.
    public var passengerCounts: [String: Int] {
        passengers.reduce(into: [:]) { $0[$1.pricingCategoryId, default: 0] += 1 }
    }
}

/// One traveller of a Toristy booking.
public struct ToristyPassenger: Sendable, Hashable {
    public var pricingCategoryId: String
    public var details: [ToristyAnswer]
    public var answers: [ToristyAnswer]
    public var extras: [ToristyExtraSelection]

    public init(pricingCategoryId: String, details: [ToristyAnswer] = [], answers: [ToristyAnswer] = [], extras: [ToristyExtraSelection] = []) {
        self.pricingCategoryId = pricingCategoryId
        self.details = details
        self.answers = answers
        self.extras = extras
    }
}

/// A chosen extra and how many of it.
public struct ToristyExtraSelection: Sendable, Hashable, Codable {
    public var extraId: String
    public var quantity: Int

    public init(extraId: String, quantity: Int) {
        self.extraId = extraId
        self.quantity = quantity
    }
}

/// A pickup or drop-off request.
public struct ToristyTransferSelection: Sendable, Hashable {
    public var placeId: Int?
    public var description: String?
    public var answers: [ToristyAnswer]

    public init(placeId: Int? = nil, description: String? = nil, answers: [ToristyAnswer] = []) {
        self.placeId = placeId
        self.description = description
        self.answers = answers
    }
}
