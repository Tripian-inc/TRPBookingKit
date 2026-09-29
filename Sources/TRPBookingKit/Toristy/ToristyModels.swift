import Foundation

/// `GET /bookingInformation/{serviceid}`: the form definition and prices of one service.
public struct ToristyBookingInformation: Sendable, Hashable, Decodable {
    public let serviceId: Int
    public let currency: String?
    public let startingPrice: Decimal?
    public let lowestPrice: Decimal?
    public let fields: ToristyBookingFields
    public let rates: [ToristyRate]
    /// Free text, shown verbatim and never parsed.
    public let cancellationPolicy: String?
    public let cancellationRules: [ToristyCancellationRule]
    public let pickupPoints: [ToristyMeetingPoint]
    public let dropoffPoints: [ToristyMeetingPoint]

    public init(serviceId: Int, currency: String?, startingPrice: Decimal?, lowestPrice: Decimal?, fields: ToristyBookingFields,
                rates: [ToristyRate], cancellationPolicy: String?, cancellationRules: [ToristyCancellationRule],
                pickupPoints: [ToristyMeetingPoint], dropoffPoints: [ToristyMeetingPoint]) {
        self.serviceId = serviceId
        self.currency = currency
        self.startingPrice = startingPrice
        self.lowestPrice = lowestPrice
        self.fields = fields
        self.rates = rates
        self.cancellationPolicy = cancellationPolicy
        self.cancellationRules = cancellationRules
        self.pickupPoints = pickupPoints
        self.dropoffPoints = dropoffPoints
    }

    public func rate(id: String) -> ToristyRate? {
        rates.first { $0.id == id }
    }

    private enum Wrapper: String, CodingKey { case bookingInformation }
    private enum CodingKeys: String, CodingKey {
        case serviceid, currency, starting_price, lowest_price, booking_fields, rates, cancellation_policy, cancellation_policy_values, meetingpoints
    }
    private enum MeetingPointKeys: String, CodingKey { case pickupitems, dropoffitems }

    public init(from decoder: Decoder) throws {
        let wrapper = try decoder.container(keyedBy: Wrapper.self)
        let container = wrapper.contains(.bookingInformation)
            ? try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .bookingInformation)
            : try decoder.container(keyedBy: CodingKeys.self)
        guard let serviceId = container.flexibleInt(.serviceid) else {
            throw DecodingError.keyNotFound(CodingKeys.serviceid, .init(codingPath: container.codingPath, debugDescription: "serviceid"))
        }
        self.serviceId = serviceId
        currency = container.flexibleString(.currency)
        startingPrice = container.flexibleDecimal(.starting_price)
        lowestPrice = container.flexibleDecimal(.lowest_price)
        fields = (try? container.decodeIfPresent(ToristyBookingFields.self, forKey: .booking_fields)) ?? ToristyBookingFields()
        rates = container.lossyArray(.rates)
        cancellationPolicy = container.flexibleString(.cancellation_policy)
        cancellationRules = container.lossyArray(.cancellation_policy_values)
        if let points = try? container.nestedContainer(keyedBy: MeetingPointKeys.self, forKey: .meetingpoints) {
            pickupPoints = points.lossyArray(.pickupitems)
            dropoffPoints = points.lossyArray(.dropoffitems)
        } else {
            pickupPoints = []
            dropoffPoints = []
        }
    }
}

/// The questions a booking must answer, as `booking_fields` defines them.
public struct ToristyBookingFields: Sendable, Hashable, Decodable {
    public let mainContact: [ToristyContactField]
    public let mainContactQuestions: [ToristyQuestion]
    public let passengerContact: [ToristyContactField]
    public let passengerQuestions: [ToristyQuestion]
    public let extraQuestions: [ToristyQuestion]

    public init(mainContact: [ToristyContactField] = [], mainContactQuestions: [ToristyQuestion] = [],
                passengerContact: [ToristyContactField] = [], passengerQuestions: [ToristyQuestion] = [],
                extraQuestions: [ToristyQuestion] = []) {
        self.mainContact = mainContact
        self.mainContactQuestions = mainContactQuestions
        self.passengerContact = passengerContact
        self.passengerQuestions = passengerQuestions
        self.extraQuestions = extraQuestions
    }

    private enum CodingKeys: String, CodingKey {
        case main_contact_fields, main_contact_additional_question, passengers_contact_fields, passengers_additional_question, extras_questions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mainContact = container.lossyArray(.main_contact_fields)
        mainContactQuestions = container.lossyArray(.main_contact_additional_question)
        passengerContact = container.lossyArray(.passengers_contact_fields)
        passengerQuestions = container.lossyArray(.passengers_additional_question)
        extraQuestions = container.lossyArray(.extras_questions)
    }
}

/// A standard contact field such as `firstName` or `email`.
public struct ToristyContactField: Sendable, Hashable, Decodable {
    public let questionId: String
    public let required: Bool

    public init(questionId: String, required: Bool) {
        self.questionId = questionId
        self.required = required
    }

    private enum CodingKeys: String, CodingKey { case questionId, required }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleString(.questionId) else {
            throw DecodingError.keyNotFound(CodingKeys.questionId, .init(codingPath: container.codingPath, debugDescription: "questionId"))
        }
        questionId = id
        required = container.flexibleBool(.required) ?? false
    }
}

/// A free-form question defined by the supplier.
public struct ToristyQuestion: Sendable, Hashable, Decodable {

    public struct Option: Sendable, Hashable, Decodable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        private enum CodingKeys: String, CodingKey { case name, value }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = container.flexibleString(.name) ?? ""
            value = container.flexibleString(.value) ?? name
        }
    }

    /// Sent back as a string, although the definition carries it as an integer.
    public let questionId: String
    public let question: String
    public let required: Bool
    public let dataType: String?
    public let allowsMultiple: Bool
    public let options: [Option]

    public init(questionId: String, question: String, required: Bool, dataType: String? = nil, allowsMultiple: Bool = false, options: [Option] = []) {
        self.questionId = questionId
        self.question = question
        self.required = required
        self.dataType = dataType
        self.allowsMultiple = allowsMultiple
        self.options = options
    }

    private enum CodingKeys: String, CodingKey { case questionId, question, required, data_type, multiple, select_options }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleString(.questionId) else {
            throw DecodingError.keyNotFound(CodingKeys.questionId, .init(codingPath: container.codingPath, debugDescription: "questionId"))
        }
        questionId = id
        question = container.flexibleString(.question) ?? id
        required = container.flexibleBool(.required) ?? false
        dataType = container.flexibleString(.data_type)
        allowsMultiple = container.flexibleBool(.multiple) ?? false
        options = container.lossyArray(.select_options)
    }
}

/// One bookable rate of a service.
public struct ToristyRate: Sendable, Hashable, Decodable {
    /// Sent back as a string in `bookingValidation`.
    public let id: String
    public let name: String
    /// Empty means the rate applies to every start time.
    public let startTimeIds: [Int]
    public let startingPrice: Decimal?
    public let prices: [ToristyPricingCategory]
    public let pickup: ToristyTransferPricing?
    public let dropoff: ToristyTransferPricing?
    public let extras: [ToristyExtra]

    public init(id: String, name: String, startTimeIds: [Int] = [], startingPrice: Decimal? = nil, prices: [ToristyPricingCategory],
                pickup: ToristyTransferPricing? = nil, dropoff: ToristyTransferPricing? = nil, extras: [ToristyExtra] = []) {
        self.id = id
        self.name = name
        self.startTimeIds = startTimeIds
        self.startingPrice = startingPrice
        self.prices = prices
        self.pickup = pickup
        self.dropoff = dropoff
        self.extras = extras
    }

    public func applies(toStartTimeId startTimeId: Int) -> Bool {
        startTimeIds.isEmpty || startTimeIds.contains(startTimeId)
    }

    public func category(id: String) -> ToristyPricingCategory? {
        prices.first { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey { case rateId, rate_name, startTimeIds, starting_price, price, pickup, dropoff, extras }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleString(.rateId) else {
            throw DecodingError.keyNotFound(CodingKeys.rateId, .init(codingPath: container.codingPath, debugDescription: "rateId"))
        }
        self.id = id
        name = container.flexibleString(.rate_name) ?? ""
        startTimeIds = container.flexibleIntArray(.startTimeIds)
        startingPrice = container.flexibleDecimal(.starting_price)
        prices = container.lossyArray(.price)
        pickup = try? container.decodeIfPresent(ToristyTransferPricing.self, forKey: .pickup)
        dropoff = try? container.decodeIfPresent(ToristyTransferPricing.self, forKey: .dropoff)
        extras = container.lossyArray(.extras)
    }
}

/// A pricing category of a rate, such as adult or child.
public struct ToristyPricingCategory: Sendable, Hashable, Decodable {

    /// A party-size step of a tiered price.
    public struct Tier: Sendable, Hashable, Decodable {
        public let amount: Decimal
        public let minPassengers: Int?
        public let maxPassengers: Int?

        public init(amount: Decimal, minPassengers: Int?, maxPassengers: Int?) {
            self.amount = amount
            self.minPassengers = minPassengers
            self.maxPassengers = maxPassengers
        }

        public func contains(_ partySize: Int) -> Bool {
            partySize >= (minPassengers ?? 0) && partySize <= (maxPassengers ?? .max)
        }

        private enum CodingKeys: String, CodingKey { case amount, minPassengersRequired, maxPassengersRequired }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            amount = container.flexibleDecimal(.amount) ?? 0
            minPassengers = container.flexibleInt(.minPassengersRequired)
            maxPassengers = container.flexibleInt(.maxPassengersRequired)
        }
    }

    /// Sent back as `pricingCategoryId`, a string.
    public let id: String
    public let name: String
    public let price: Decimal?
    public let tiers: [Tier]
    public let minAge: Int?
    public let maxAge: Int?
    public let minPerBooking: Int?
    public let maxPerBooking: Int?
    public let category: String?

    public init(id: String, name: String, price: Decimal?, tiers: [Tier] = [], minAge: Int? = nil, maxAge: Int? = nil,
                minPerBooking: Int? = nil, maxPerBooking: Int? = nil, category: String? = nil) {
        self.id = id
        self.name = name
        self.price = price
        self.tiers = tiers
        self.minAge = minAge
        self.maxAge = maxAge
        self.minPerBooking = minPerBooking
        self.maxPerBooking = maxPerBooking
        self.category = category
    }

    /// The per-passenger price for a party of `partySize`, taking tiers into account.
    public func unitPrice(forPartySize partySize: Int) -> Decimal? {
        tiers.first { $0.contains(partySize) }?.amount ?? price
    }

    private enum CodingKeys: String, CodingKey {
        case pricingcategoryid, name, price, tieredprice, min_age, max_age, min_per_booking, max_per_booking, category
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleString(.pricingcategoryid) else {
            throw DecodingError.keyNotFound(CodingKeys.pricingcategoryid, .init(codingPath: container.codingPath, debugDescription: "pricingcategoryid"))
        }
        self.id = id
        name = container.flexibleString(.name) ?? ""
        price = container.flexibleDecimal(.price)
        tiers = container.lossyArray(.tieredprice)
        minAge = container.flexibleInt(.min_age)
        maxAge = container.flexibleInt(.max_age)
        minPerBooking = container.flexibleInt(.min_per_booking)
        maxPerBooking = container.flexibleInt(.max_per_booking)
        category = container.flexibleString(.category)
    }
}

/// Pickup or drop-off prices of a rate.
public struct ToristyTransferPricing: Sendable, Hashable, Decodable {

    public struct Price: Sendable, Hashable, Decodable {
        public let pricingCategoryId: String?
        public let price: Decimal
        public let name: String?

        public init(pricingCategoryId: String?, price: Decimal, name: String?) {
            self.pricingCategoryId = pricingCategoryId
            self.price = price
            self.name = name
        }

        private enum CodingKeys: String, CodingKey { case pricingcategoryid, price, name }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pricingCategoryId = container.flexibleString(.pricingcategoryid)
            price = container.flexibleDecimal(.price) ?? 0
            name = container.flexibleString(.name)
        }
    }

    public let prices: [Price]
    public let pricePer: ToristyPricePer

    public init(prices: [Price], pricePer: ToristyPricePer) {
        self.prices = prices
        self.pricePer = pricePer
    }

    private enum CodingKeys: String, CodingKey { case prices, priceper }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prices = container.lossyArray(.prices)
        pricePer = ToristyPricePer(container.flexibleString(.priceper))
    }
}

/// Whether a price is multiplied by the passenger count.
public enum ToristyPricePer: String, Sendable, Hashable {
    case person
    case booking

    /// Reads the provider's string; anything but "booking" counts per person.
    public init(_ raw: String?) {
        self = raw?.lowercased().contains("booking") == true ? .booking : .person
    }
}

/// An optional extra of a rate.
public struct ToristyExtra: Sendable, Hashable, Decodable {
    /// Sent back as `extraId`.
    public let id: String
    public let name: String
    public let price: Decimal
    public let pricePer: ToristyPricePer
    /// The raw limit rule, such as "per_passenger" or "per_booking".
    public let limitType: String?
    public let limit: Int?

    public init(id: String, name: String, price: Decimal, pricePer: ToristyPricePer, limitType: String? = nil, limit: Int? = nil) {
        self.id = id
        self.name = name
        self.price = price
        self.pricePer = pricePer
        self.limitType = limitType
        self.limit = limit
    }

    /// Whether the limit counts per passenger rather than across the booking.
    public var isLimitPerPassenger: Bool {
        limitType?.lowercased().contains("passenger") == true || limitType?.lowercased().contains("person") == true
    }

    private enum CodingKeys: String, CodingKey { case serviceextraid, name, price, priceper, limittype, limitnum }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleString(.serviceextraid) else {
            throw DecodingError.keyNotFound(CodingKeys.serviceextraid, .init(codingPath: container.codingPath, debugDescription: "serviceextraid"))
        }
        self.id = id
        name = container.flexibleString(.name) ?? ""
        price = container.flexibleDecimal(.price) ?? 0
        pricePer = ToristyPricePer(container.flexibleString(.priceper))
        limitType = container.flexibleString(.limittype)
        let limit = container.flexibleInt(.limitnum)
        self.limit = (limit ?? 0) > 0 ? limit : nil
    }
}

/// A structured cancellation rule; the free-text policy stays the authority.
public struct ToristyCancellationRule: Sendable, Hashable, Decodable {
    public let feePercentage: Decimal
    /// The rule applies when fewer than this many hours are left before the start.
    public let cutoffHours: Int

    public init(feePercentage: Decimal, cutoffHours: Int) {
        self.feePercentage = feePercentage
        self.cutoffHours = cutoffHours
    }

    private enum CodingKeys: String, CodingKey { case fee_percentage, days, hours, cutoff_hours }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feePercentage = container.flexibleDecimal(.fee_percentage) ?? 0
        cutoffHours = container.flexibleInt(.cutoff_hours)
            ?? (container.flexibleInt(.days) ?? 0) * 24 + (container.flexibleInt(.hours) ?? 0)
    }
}

/// A pickup or drop-off place.
public struct ToristyMeetingPoint: Sendable, Hashable, Decodable {
    public let id: Int
    public let title: String

    public init(id: Int, title: String) {
        self.id = id
        self.title = title
    }

    private enum CodingKeys: String, CodingKey { case meetingpointid, title }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleInt(.meetingpointid) else {
            throw DecodingError.keyNotFound(CodingKeys.meetingpointid, .init(codingPath: container.codingPath, debugDescription: "meetingpointid"))
        }
        self.id = id
        title = container.flexibleString(.title) ?? ""
    }
}

/// `GET /availabilities/{serviceid}`: departures per day.
public struct ToristyAvailability: Sendable, Hashable, Decodable {
    public let serviceId: Int?
    public let days: [ToristyAvailabilityDay]

    public init(serviceId: Int?, days: [ToristyAvailabilityDay]) {
        self.serviceId = serviceId
        self.days = days
    }

    public func day(_ date: BookingDate) -> ToristyAvailabilityDay? {
        days.first { $0.date == date }
    }

    private enum Wrapper: String, CodingKey { case availabilities }
    private enum CodingKeys: String, CodingKey { case serviceid, availability }

    public init(from decoder: Decoder) throws {
        let wrapper = try decoder.container(keyedBy: Wrapper.self)
        let container = wrapper.contains(.availabilities)
            ? try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .availabilities)
            : try decoder.container(keyedBy: CodingKeys.self)
        serviceId = container.flexibleInt(.serviceid)
        days = container.lossyArray(.availability)
    }
}

/// One calendar day; no times means nothing is bookable that day.
public struct ToristyAvailabilityDay: Sendable, Hashable, Decodable {
    public let date: BookingDate
    public let times: [ToristyStartTime]

    public init(date: BookingDate, times: [ToristyStartTime]) {
        self.date = date
        self.times = times
    }

    /// Departures that can still be booked.
    public var bookableTimes: [ToristyStartTime] {
        times.filter(\.isBookable)
    }

    private enum CodingKeys: String, CodingKey { case date, times }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let date = BookingDate(container.flexibleString(.date) ?? "") else {
            throw DecodingError.dataCorruptedError(forKey: .date, in: container, debugDescription: "date")
        }
        self.date = date
        times = container.lossyArray(.times)
    }
}

/// One departure of a day.
public struct ToristyStartTime: Sendable, Hashable, Decodable {
    /// "HH:MM", used to build the `date` of a validation.
    public let time: String
    public let id: Int
    public let pricePer: ToristyPricePer
    /// Meaningless when `isUnlimited`.
    public let availableCount: Int
    public let isUnlimited: Bool
    public let minParticipants: Int
    public let hasSeparatePickupAllotment: Bool
    public let pickupAvailableCount: Int?
    public let isPickupSoldOut: Bool
    public let defaultRateId: String?
    public let isUnavailable: Bool
    public let isSoldOut: Bool
    public let rates: [ToristyStartTimeRate]

    public init(time: String, id: Int, pricePer: ToristyPricePer = .person, availableCount: Int, isUnlimited: Bool = false,
                minParticipants: Int = 0, hasSeparatePickupAllotment: Bool = false, pickupAvailableCount: Int? = nil,
                isPickupSoldOut: Bool = false, defaultRateId: String? = nil, isUnavailable: Bool = false, isSoldOut: Bool = false,
                rates: [ToristyStartTimeRate] = []) {
        self.time = time
        self.id = id
        self.pricePer = pricePer
        self.availableCount = availableCount
        self.isUnlimited = isUnlimited
        self.minParticipants = minParticipants
        self.hasSeparatePickupAllotment = hasSeparatePickupAllotment
        self.pickupAvailableCount = pickupAvailableCount
        self.isPickupSoldOut = isPickupSoldOut
        self.defaultRateId = defaultRateId
        self.isUnavailable = isUnavailable
        self.isSoldOut = isSoldOut
        self.rates = rates
    }

    public var isBookable: Bool {
        !isSoldOut && !isUnavailable && (isUnlimited || availableCount > 0)
    }

    /// Seats left to show as "N left", or `nil` when capacity is unlimited.
    public var seatsLeft: Int? {
        isUnlimited ? nil : availableCount
    }

    public func rate(id: String) -> ToristyStartTimeRate? {
        rates.first { String($0.id) == id }
    }

    private enum CodingKeys: String, CodingKey {
        case time, starttimeid, priceper, availabilityCount, pickupAllotment, unlimitedAvailability, minParticipants,
             minParticipantsToBookNow, pickupAvailabilityCount, defaultRateId, unavailable, pickupSoldOut, soldOut, rates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleInt(.starttimeid) else {
            throw DecodingError.keyNotFound(CodingKeys.starttimeid, .init(codingPath: container.codingPath, debugDescription: "starttimeid"))
        }
        self.id = id
        time = container.flexibleString(.time) ?? ""
        pricePer = ToristyPricePer(container.flexibleString(.priceper))
        availableCount = container.flexibleInt(.availabilityCount) ?? 0
        isUnlimited = container.flexibleBool(.unlimitedAvailability) ?? false
        minParticipants = max(container.flexibleInt(.minParticipantsToBookNow) ?? 0, container.flexibleInt(.minParticipants) ?? 0)
        hasSeparatePickupAllotment = container.flexibleBool(.pickupAllotment) ?? false
        pickupAvailableCount = container.flexibleInt(.pickupAvailabilityCount)
        isPickupSoldOut = container.flexibleBool(.pickupSoldOut) ?? false
        defaultRateId = container.flexibleString(.defaultRateId)
        isUnavailable = container.flexibleBool(.unavailable) ?? false
        isSoldOut = container.flexibleBool(.soldOut) ?? false
        rates = container.lossyArray(.rates)
    }
}

/// The per-departure view of a rate: its passenger bounds and which categories it takes.
public struct ToristyStartTimeRate: Sendable, Hashable, Decodable {

    public enum SelectionType: String, Sendable, Hashable {
        case optional = "OPTIONAL"
        case preselected = "PRESELECTED"
        case unavailable = "UNAVAILABLE"
    }

    public let id: Int
    public let title: String?
    public let pricedPerPerson: Bool
    public let minPerBooking: Int?
    public let maxPerBooking: Int?
    public let pickupSelection: SelectionType?
    public let dropoffSelection: SelectionType?
    /// Empty means every category of the rate is accepted.
    public let pricingCategoryIds: [Int]

    public init(id: Int, title: String? = nil, pricedPerPerson: Bool = true, minPerBooking: Int? = nil, maxPerBooking: Int? = nil,
                pickupSelection: SelectionType? = nil, dropoffSelection: SelectionType? = nil, pricingCategoryIds: [Int] = []) {
        self.id = id
        self.title = title
        self.pricedPerPerson = pricedPerPerson
        self.minPerBooking = minPerBooking
        self.maxPerBooking = maxPerBooking
        self.pickupSelection = pickupSelection
        self.dropoffSelection = dropoffSelection
        self.pricingCategoryIds = pricingCategoryIds
    }

    public func accepts(pricingCategoryId: String) -> Bool {
        pricingCategoryIds.isEmpty || pricingCategoryIds.map(String.init).contains(pricingCategoryId)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, pricedPerPerson, minPerBooking, maxPerBooking, pickupSelectionType, dropoffSelectionType, pricingCategoryIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleInt(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: container.codingPath, debugDescription: "id"))
        }
        self.id = id
        title = container.flexibleString(.title)
        pricedPerPerson = container.flexibleBool(.pricedPerPerson) ?? true
        let minPerBooking = container.flexibleInt(.minPerBooking)
        let maxPerBooking = container.flexibleInt(.maxPerBooking)
        self.minPerBooking = (minPerBooking ?? 0) > 0 ? minPerBooking : nil
        self.maxPerBooking = (maxPerBooking ?? 0) > 0 ? maxPerBooking : nil
        pickupSelection = container.flexibleString(.pickupSelectionType).flatMap { SelectionType(rawValue: $0.uppercased()) }
        dropoffSelection = container.flexibleString(.dropoffSelectionType).flatMap { SelectionType(rawValue: $0.uppercased()) }
        pricingCategoryIds = container.flexibleIntArray(.pricingCategoryIds)
    }
}

/// An answer to a contact field or question, sent in `bookingValidation`.
public struct ToristyAnswer: Sendable, Hashable, Codable {
    public let questionId: String
    public let values: [String]

    public init(questionId: String, values: [String]) {
        self.questionId = questionId
        self.values = values
    }

    public init(questionId: String, value: String) {
        self.init(questionId: questionId, values: [value])
    }

    /// Whether every value is blank.
    public var isBlank: Bool {
        values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// `POST /bookingValidation` answer: the cart that is now held for 30 minutes.
public struct ToristyValidation: Sendable, Hashable, Decodable {
    public let cartId: String
    public let confirmationCode: String
    /// The amount to charge; sent as a string by this call.
    public let totalPrice: Decimal
    public let currency: String

    public init(cartId: String, confirmationCode: String, totalPrice: Decimal, currency: String) {
        self.cartId = cartId
        self.confirmationCode = confirmationCode
        self.totalPrice = totalPrice
        self.currency = currency
    }

    public var reference: BookingReference {
        BookingReference(provider: .toristy, primary: cartId, secondary: confirmationCode)
    }

    private enum CodingKeys: String, CodingKey { case cartid, confirmationCode, totalPrice, currency }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let cartId = container.flexibleString(.cartid), let code = container.flexibleString(.confirmationCode) else {
            throw DecodingError.keyNotFound(CodingKeys.cartid, .init(codingPath: container.codingPath, debugDescription: "cartid/confirmationCode"))
        }
        guard let total = container.flexibleDecimal(.totalPrice) else {
            throw DecodingError.keyNotFound(CodingKeys.totalPrice, .init(codingPath: container.codingPath, debugDescription: "totalPrice"))
        }
        self.cartId = cartId
        confirmationCode = code
        totalPrice = total
        currency = container.flexibleString(.currency) ?? ""
    }
}

/// Where a Toristy cart stands; `paymentStatus` of `bookingdata`.
public enum ToristyPaymentStatus: Sendable, Hashable {
    case confirmed
    case reserved
    case cancelled
    case timedOut
    case other(String)

    public init(_ raw: String) {
        switch raw.lowercased().replacingOccurrences(of: " ", with: "") {
        case "confirmed": self = .confirmed
        case "reserved": self = .reserved
        case "cancelled", "canceled": self = .cancelled
        case "timedout": self = .timedOut
        default: self = .other(raw)
        }
    }

    public var recordStatus: BookingRecordStatus? {
        switch self {
        case .confirmed: return .confirmed
        case .reserved: return .held
        case .cancelled: return .cancelled
        case .timedOut: return .expired
        case .other: return nil
        }
    }
}

/// `GET /bookingdata/{cartid}`: the authority on a cart's state.
public struct ToristyBookingData: Sendable, Hashable, Decodable {
    public let cartId: String
    public let confirmationCode: String?
    public let currency: String?
    /// A number in this call, unlike `bookingValidation`.
    public let totalPrice: Decimal?
    public let createdAt: Date?
    public let expiresAt: Date?
    public let status: ToristyPaymentStatus
    /// The `date` of the first activity booking, "YYYY-MM-DD HH:MM".
    public let activityDate: String?

    public init(cartId: String, confirmationCode: String?, currency: String?, totalPrice: Decimal?, createdAt: Date?,
                expiresAt: Date?, status: ToristyPaymentStatus, activityDate: String? = nil) {
        self.cartId = cartId
        self.confirmationCode = confirmationCode
        self.currency = currency
        self.totalPrice = totalPrice
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.status = status
        self.activityDate = activityDate
    }

    public var deadline: BookingDeadline? {
        expiresAt.map(BookingDeadline.init(expiresAt:))
    }

    private enum Wrapper: String, CodingKey { case booking }
    private enum CodingKeys: String, CodingKey { case cartId, cartid, confirmationCode, currency, totalPrice, createdDate, expiryDate, paymentStatus, activityBookings }
    private struct ActivityDate: Decodable { let date: String? }

    public init(from decoder: Decoder) throws {
        let wrapper = try decoder.container(keyedBy: Wrapper.self)
        let container = wrapper.contains(.booking)
            ? try wrapper.nestedContainer(keyedBy: CodingKeys.self, forKey: .booking)
            : try decoder.container(keyedBy: CodingKeys.self)
        guard let cartId = container.flexibleString(.cartId) ?? container.flexibleString(.cartid) else {
            throw DecodingError.keyNotFound(CodingKeys.cartId, .init(codingPath: container.codingPath, debugDescription: "cartId"))
        }
        self.cartId = cartId
        confirmationCode = container.flexibleString(.confirmationCode)
        currency = container.flexibleString(.currency)
        totalPrice = container.flexibleDecimal(.totalPrice)
        createdAt = ToristyDates.timestamp(container.flexibleString(.createdDate))
        expiresAt = ToristyDates.timestamp(container.flexibleString(.expiryDate))
        status = ToristyPaymentStatus(container.flexibleString(.paymentStatus) ?? "")
        let bookings: [ActivityDate] = container.lossyArray(.activityBookings)
        activityDate = bookings.first?.date
    }
}

/// `POST /bookingcancel` answer.
public struct ToristyCancellation: Sendable, Hashable, Decodable {
    public let message: String?
    public let confirmationCode: String?

    public init(message: String?, confirmationCode: String?) {
        self.message = message
        self.confirmationCode = confirmationCode
    }
}

/// Toristy's error body, `{errorcode, message}`.
struct ToristyErrorBody: Decodable {
    let errorcode: String?
    let message: String?

    private enum CodingKeys: String, CodingKey { case errorcode, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errorcode = container.flexibleString(.errorcode)
        message = container.flexibleString(.message)
    }
}

/// Reads the timestamps Toristy sends, ISO 8601 or "YYYY-MM-DD HH:MM:SS" in UTC.
enum ToristyDates {
    static func timestamp(_ string: String?) -> Date? {
        if let date = ISO8601.date(from: string) { return date }
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
