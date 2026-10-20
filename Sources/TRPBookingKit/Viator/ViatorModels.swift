import Foundation

/// Viator's traveller age bands; `traveler` means the product makes no age distinction.
public enum ViatorAgeBand: String, Sendable, Hashable, Codable, CaseIterable {
    case adult = "ADULT"
    case child = "CHILD"
    case infant = "INFANT"
    case senior = "SENIOR"
    case youth = "YOUTH"
    case traveler = "TRAVELER"
}

/// The booking-relevant part of `GET /products/{productCode}`.
public struct ViatorProduct: Sendable, Hashable, Decodable {
    public let productCode: String
    public let title: String?
    /// The minimum bookable date is computed in this zone, not the device's.
    public let timeZone: TimeZone
    public let ageBands: [ViatorAgeBandRule]
    public let minTravelersPerBooking: Int
    public let maxTravelersPerBooking: Int?
    public let bookingQuestionIds: [String]
    public let languageGuides: [ViatorLanguageGuide]
    public let options: [ViatorProductOption]
    public let pickupOptionType: String?
    public let pickupLocationRefs: [String]
    public let startLocationRefs: [String]
    public let endLocationRefs: [String]
    public let cancellationPolicy: ViatorCancellationPolicy?

    /// Every `location.ref` in the logistics, for `POST /locations/bulk`.
    public var locationRefs: [String] {
        var seen = Set<String>()
        return (pickupLocationRefs + startLocationRefs + endLocationRefs).filter { seen.insert($0).inserted }
    }

    /// Whether the product prices every traveller as `TRAVELER`.
    public var usesTravelerBand: Bool {
        ageBands.contains { $0.ageBand == .traveler }
    }

    public func option(code: String) -> ViatorProductOption? {
        options.first { $0.productOptionCode == code }
    }

    private enum CodingKeys: String, CodingKey {
        case productCode, title, timeZone, pricingInfo, bookingRequirements, bookingQuestions, languageGuides, productOptions, logistics, cancellationPolicy
    }
    private enum PricingKeys: String, CodingKey { case ageBands }
    private enum RequirementKeys: String, CodingKey { case minTravelersPerBooking, maxTravelersPerBooking }
    private enum LogisticsKeys: String, CodingKey { case travelerPickup, start, end }
    private enum PickupKeys: String, CodingKey { case pickupOptionType, locations }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productCode = try container.decode(String.self, forKey: .productCode)
        title = container.flexibleString(.title)
        timeZone = container.flexibleString(.timeZone).flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!

        let pricing = try? container.nestedContainer(keyedBy: PricingKeys.self, forKey: .pricingInfo)
        ageBands = pricing?.lossyArray(.ageBands) ?? []

        let requirements = try? container.nestedContainer(keyedBy: RequirementKeys.self, forKey: .bookingRequirements)
        minTravelersPerBooking = requirements?.flexibleInt(.minTravelersPerBooking) ?? 1
        maxTravelersPerBooking = requirements?.flexibleInt(.maxTravelersPerBooking)

        bookingQuestionIds = (try? container.decode([String].self, forKey: .bookingQuestions)) ?? []
        languageGuides = container.lossyArray(.languageGuides)
        options = container.lossyArray(.productOptions)
        cancellationPolicy = try? container.decode(ViatorCancellationPolicy.self, forKey: .cancellationPolicy)

        let logistics = try? container.nestedContainer(keyedBy: LogisticsKeys.self, forKey: .logistics)
        let pickup = try? logistics?.nestedContainer(keyedBy: PickupKeys.self, forKey: .travelerPickup)
        pickupOptionType = pickup?.flexibleString(.pickupOptionType)
        pickupLocationRefs = pickup.map { ViatorLocationRef.refs(in: $0, key: .locations) } ?? []
        startLocationRefs = logistics.map { ViatorLocationRef.refs(in: $0, key: .start) } ?? []
        endLocationRefs = logistics.map { ViatorLocationRef.refs(in: $0, key: .end) } ?? []
    }
}

/// A `{ "location": { "ref": … } }` wrapper from the logistics block.
struct ViatorLocationRef: Decodable {
    let ref: String?

    private enum CodingKeys: String, CodingKey { case location }
    private enum LocationKeys: String, CodingKey { case ref }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = (try? container.nestedContainer(keyedBy: LocationKeys.self, forKey: .location))?.flexibleString(.ref)
    }

    static func refs<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, key: Key) -> [String] {
        let wrappers: [ViatorLocationRef] = container.lossyArray(key)
        return wrappers.compactMap(\.ref)
    }
}

/// Per-band traveller limits, enforced in addition to the booking-level ones.
public struct ViatorAgeBandRule: Sendable, Hashable, Decodable {
    public let ageBand: ViatorAgeBand
    public let startAge: Int?
    public let endAge: Int?
    public let minTravelersPerBooking: Int
    public let maxTravelersPerBooking: Int?

    private enum CodingKeys: String, CodingKey { case ageBand, startAge, endAge, minTravelersPerBooking, maxTravelersPerBooking }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ageBand = try container.decode(ViatorAgeBand.self, forKey: .ageBand)
        startAge = container.flexibleInt(.startAge)
        endAge = container.flexibleInt(.endAge)
        minTravelersPerBooking = container.flexibleInt(.minTravelersPerBooking) ?? 0
        maxTravelersPerBooking = container.flexibleInt(.maxTravelersPerBooking)
    }
}

/// A bookable variant of a product.
public struct ViatorProductOption: Sendable, Hashable, Decodable {
    public let productOptionCode: String
    public let title: String?
    /// May contain HTML.
    public let description: String?
    public let languageGuides: [ViatorLanguageGuide]

    private enum CodingKeys: String, CodingKey { case productOptionCode, title, description, languageGuides }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productOptionCode = try container.decode(String.self, forKey: .productOptionCode)
        title = container.flexibleString(.title)
        description = container.flexibleString(.description)
        languageGuides = container.lossyArray(.languageGuides)
    }
}

/// A guide language, sent back as `languageGuide` in `cart/book`.
public struct ViatorLanguageGuide: Sendable, Hashable, Codable {
    public let type: String
    public let language: String
    public let legacyGuide: String?

    public init(type: String, language: String, legacyGuide: String? = nil) {
        self.type = type
        self.language = language
        self.legacyGuide = legacyGuide
    }

    /// The guide to book from `guides`: the first one in the app's language, otherwise the first offered.
    /// Viator refuses `cart/book` without one whenever the option offers any.
    public static func preferred(from guides: [ViatorLanguageGuide], languageCode: String) -> ViatorLanguageGuide? {
        let wanted = ViatorAPIClient.acceptLanguage(for: languageCode).lowercased()
        let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
        return guides.first { $0.language.lowercased() == wanted }
            ?? guides.first { $0.language.lowercased().hasPrefix(base) }
            ?? guides.first
    }
}

/// `GET /availability/schedules/{productCode}`, for the date picker only.
public struct ViatorSchedule: Sendable, Hashable, Decodable {
    public let productCode: String
    public let currency: String?
    public let fromPrice: Decimal?
    public let bookableItems: [Item]

    public struct Item: Sendable, Hashable, Decodable {
        public let productOptionCode: String?
        public let seasons: [Season]

        private enum CodingKeys: String, CodingKey { case productOptionCode, seasons }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            productOptionCode = container.flexibleString(.productOptionCode)
            seasons = container.lossyArray(.seasons)
        }
    }

    public struct Season: Sendable, Hashable, Decodable {
        public let startDate: BookingDate
        /// `nil` means open-ended.
        public let endDate: BookingDate?
        public let pricingRecords: [PricingRecord]

        private enum CodingKeys: String, CodingKey { case startDate, endDate, pricingRecords }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let start = container.flexibleString(.startDate).flatMap(BookingDate.init) else {
                throw DecodingError.dataCorruptedError(forKey: .startDate, in: container, debugDescription: "Missing startDate")
            }
            startDate = start
            endDate = container.flexibleString(.endDate).flatMap(BookingDate.init)
            pricingRecords = container.lossyArray(.pricingRecords)
        }

        public func contains(_ date: BookingDate) -> Bool {
            date >= startDate && endDate.map { date <= $0 } ?? true
        }
    }

    public struct PricingRecord: Sendable, Hashable, Decodable {
        /// Upper-cased English weekday names; empty means every day.
        public let daysOfWeek: [String]
        public let timedEntries: [TimedEntry]

        private enum CodingKeys: String, CodingKey { case daysOfWeek, timedEntries }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            daysOfWeek = ((try? container.decode([String].self, forKey: .daysOfWeek)) ?? []).map { $0.uppercased() }
            timedEntries = container.lossyArray(.timedEntries)
        }
    }

    public struct TimedEntry: Sendable, Hashable, Decodable {
        public let startTime: String?
        public let unavailableDates: Set<BookingDate>

        private enum CodingKeys: String, CodingKey { case startTime, unavailableDates }
        private struct Unavailable: Decodable { let date: String }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            startTime = container.flexibleString(.startTime)
            let blocked: [Unavailable] = container.lossyArray(.unavailableDates)
            unavailableDates = Set(blocked.compactMap { BookingDate($0.date) })
        }
    }

    private enum CodingKeys: String, CodingKey { case productCode, currency, summary, bookableItems }
    private enum SummaryKeys: String, CodingKey { case fromPrice }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productCode = container.flexibleString(.productCode) ?? ""
        currency = container.flexibleString(.currency)
        fromPrice = (try? container.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary))?.flexibleDecimal(.fromPrice)
        bookableItems = container.lossyArray(.bookableItems)
    }
}

/// An entry of the cacheable `GET /products/booking-questions` dictionary.
public struct ViatorBookingQuestion: Sendable, Hashable, Decodable {

    public enum Group: String, Sendable, Hashable, Decodable {
        case perTraveler = "PER_TRAVELER"
        case perBooking = "PER_BOOKING"
    }

    public enum Requirement: String, Sendable, Hashable, Decodable {
        case mandatory = "MANDATORY"
        case optional = "OPTIONAL"
        case conditional = "CONDITIONAL"
    }

    public static let pickupPointId = "PICKUP_POINT"

    /// Sent back as `question`; never the label.
    public let id: String
    public let type: String
    public let group: Group
    public let label: String
    public let required: Requirement
    public let maxLength: Int?
    public let units: [String]
    public let allowedAnswers: [String]
    public let hint: String?

    /// `NUMBER_AND_UNIT` answers must carry one of `units`.
    public var requiresUnit: Bool { type == "NUMBER_AND_UNIT" }

    private enum CodingKeys: String, CodingKey { case id, type, group, label, required, maxLength, units, allowedAnswers, hint }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = container.flexibleString(.type) ?? "STRING"
        group = (try? container.decode(Group.self, forKey: .group)) ?? .perBooking
        label = container.flexibleString(.label) ?? id
        required = (try? container.decode(Requirement.self, forKey: .required)) ?? .optional
        maxLength = container.flexibleInt(.maxLength)
        units = (try? container.decode([String].self, forKey: .units)) ?? []
        allowedAnswers = (try? container.decode([String].self, forKey: .allowedAnswers)) ?? []
        hint = container.flexibleString(.hint)
    }
}

/// A resolved `location.ref` from `POST /locations/bulk`.
public struct ViatorLocation: Sendable, Hashable, Decodable {
    /// Sent as the `PICKUP_POINT` answer.
    public let reference: String
    public let name: String?
    public let address: String?
    public let latitude: Double?
    public let longitude: Double?

    private enum CodingKeys: String, CodingKey { case reference, name, address, center }
    private enum AddressKeys: String, CodingKey { case street, administrativeArea, state, country, postcode }
    private enum CenterKeys: String, CodingKey { case latitude, longitude }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reference = try container.decode(String.self, forKey: .reference)
        name = container.flexibleString(.name)
        if let parts = try? container.nestedContainer(keyedBy: AddressKeys.self, forKey: .address) {
            let lines = [AddressKeys.street, .administrativeArea, .state, .postcode, .country].compactMap { parts.flexibleString($0) }
            address = lines.isEmpty ? nil : lines.joined(separator: ", ")
        } else {
            address = nil
        }
        let center = try? container.nestedContainer(keyedBy: CenterKeys.self, forKey: .center)
        latitude = center.flatMap { try? $0.decode(Double.self, forKey: .latitude) }
        longitude = center.flatMap { try? $0.decode(Double.self, forKey: .longitude) }
    }
}

struct ViatorLocationsResponse: Decodable {
    let locations: [ViatorLocation]

    private enum CodingKeys: String, CodingKey { case locations }

    init(from decoder: Decoder) throws {
        locations = try decoder.container(keyedBy: CodingKeys.self).lossyArray(.locations)
    }
}

/// One band's traveller count; only bands with a count above zero are sent.
public struct ViatorPax: Sendable, Hashable, Codable {
    public let ageBand: ViatorAgeBand
    public let numberOfTravelers: Int

    public init(ageBand: ViatorAgeBand, numberOfTravelers: Int) {
        self.ageBand = ageBand
        self.numberOfTravelers = numberOfTravelers
    }
}

/// Viator's price block; only `recommendedRetailPrice` is ever shown to the customer.
public struct ViatorPrice: Sendable, Hashable, Decodable {
    public let recommendedRetailPrice: Decimal?
    public let partnerNetPrice: Decimal?
    public let bookingFee: Decimal?
    public let partnerTotalPrice: Decimal?

    private enum OuterKeys: String, CodingKey { case price }
    private enum CodingKeys: String, CodingKey { case recommendedRetailPrice, partnerNetPrice, bookingFee, partnerTotalPrice }

    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: OuterKeys.self)
        let container = try (try? outer.nestedContainer(keyedBy: CodingKeys.self, forKey: .price)) ?? decoder.container(keyedBy: CodingKeys.self)
        recommendedRetailPrice = container.flexibleDecimal(.recommendedRetailPrice)
        partnerNetPrice = container.flexibleDecimal(.partnerNetPrice)
        bookingFee = container.flexibleDecimal(.bookingFee)
        partnerTotalPrice = container.flexibleDecimal(.partnerTotalPrice)
    }
}

struct ViatorAvailabilityRequest: Encodable {
    let productCode: String
    let travelDate: BookingDate
    let currency: String
    let paxMix: [ViatorPax]
}

/// `POST /availability/check` for a date, every option and start time at once.
public struct ViatorAvailability: Sendable, Hashable, Decodable {
    public let productCode: String
    public let travelDate: BookingDate?
    public let currency: String
    public let bookableItems: [Item]

    public struct Item: Sendable, Hashable, Decodable {
        public let productOptionCode: String
        /// Absent for products without start times; omit it in `cart/hold` too.
        public let startTime: String?
        public let available: Bool
        /// "Sold out" and "below minimum" need different copy.
        public let unavailableReason: String?
        public let lineItems: [LineItem]
        public let totalPrice: ViatorPrice?

        private enum CodingKeys: String, CodingKey { case productOptionCode, startTime, available, unavailableReason, lineItems, totalPrice }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            productOptionCode = container.flexibleString(.productOptionCode) ?? ""
            startTime = container.flexibleString(.startTime)
            available = container.flexibleBool(.available) ?? false
            unavailableReason = container.flexibleString(.unavailableReason)
            lineItems = container.lossyArray(.lineItems)
            totalPrice = try? container.decode(ViatorPrice.self, forKey: .totalPrice)
        }
    }

    public struct LineItem: Sendable, Hashable, Decodable {
        public let ageBand: ViatorAgeBand?
        public let numberOfTravelers: Int
        public let subtotalPrice: ViatorPrice?

        private enum CodingKeys: String, CodingKey { case ageBand, numberOfTravelers, subtotalPrice }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ageBand = try? container.decode(ViatorAgeBand.self, forKey: .ageBand)
            numberOfTravelers = container.flexibleInt(.numberOfTravelers) ?? 0
            subtotalPrice = try? container.decode(ViatorPrice.self, forKey: .subtotalPrice)
        }
    }

    /// Items grouped by option, in the order Viator sent them, for option cards.
    public var itemsByOption: [(optionCode: String, items: [Item])] {
        var order: [String] = []
        var groups: [String: [Item]] = [:]
        for item in bookableItems {
            if groups[item.productOptionCode] == nil { order.append(item.productOptionCode) }
            groups[item.productOptionCode, default: []].append(item)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private enum CodingKeys: String, CodingKey { case productCode, travelDate, currency, bookableItems }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productCode = container.flexibleString(.productCode) ?? ""
        travelDate = container.flexibleString(.travelDate).flatMap(BookingDate.init)
        currency = container.flexibleString(.currency) ?? ""
        bookableItems = container.lossyArray(.bookableItems)
    }
}

/// A rate from `POST /exchange-rates`, valid until `expiry`.
public struct ViatorExchangeRate: Sendable, Hashable, Decodable {
    public let sourceCurrency: String
    public let targetCurrency: String
    public let rate: Decimal
    public let expiry: Date?

    private enum CodingKeys: String, CodingKey { case sourceCurrency, targetCurrency, rate, expiry }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceCurrency = try container.decode(String.self, forKey: .sourceCurrency)
        targetCurrency = try container.decode(String.self, forKey: .targetCurrency)
        rate = container.flexibleDecimal(.rate) ?? 0
        expiry = ISO8601.date(from: container.flexibleString(.expiry))
    }
}

struct ViatorExchangeRatesRequest: Encodable {
    let sourceCurrencies: [String]
    let targetCurrencies: [String]
}

struct ViatorExchangeRatesResponse: Decodable {
    let rates: [ViatorExchangeRate]

    private enum CodingKeys: String, CodingKey { case rates }

    init(from decoder: Decoder) throws {
        rates = try decoder.container(keyedBy: CodingKeys.self).lossyArray(.rates)
    }
}

/// What to hold: one option and start time for a date and party.
public struct ViatorHoldItem: Sendable, Hashable {
    public let productCode: String
    public let productOptionCode: String
    public let startTime: String?
    public let travelDate: BookingDate
    public let paxMix: [ViatorPax]

    public init(productCode: String, productOptionCode: String, startTime: String?, travelDate: BookingDate, paxMix: [ViatorPax]) {
        self.productCode = productCode
        self.productOptionCode = productOptionCode
        self.startTime = startTime
        self.travelDate = travelDate
        self.paxMix = paxMix.filter { $0.numberOfTravelers > 0 }
    }
}

struct ViatorHoldRequest: Encodable {
    struct Item: Encodable {
        let partnerBookingRef: String
        let productCode: String
        let productOptionCode: String
        let startTime: String?
        let travelDate: BookingDate
        let paxMix: [ViatorPax]
    }

    let currency: String
    let partnerCartRef: String
    let items: [Item]
    let paymentDataSubmissionMode = "VIATOR_FORM"
    let hostingUrl: String
}

/// The answer to `POST /bookings/cart/hold`.
public struct ViatorHold: Sendable, Hashable, Decodable {
    public let cartRef: String
    public let partnerCartRef: String?
    public let currency: String
    public let items: [Item]
    public let totalHeldPrice: ViatorPrice?
    /// Initialises the hosted payment form. Kept in memory only.
    public let paymentSessionToken: String?

    public struct Item: Sendable, Hashable, Decodable {
        public let partnerBookingRef: String?
        public let bookingRef: String
        public let status: String
        public let rejectionReasonCode: String?
        public let itemTotalPrice: ViatorPrice?
        /// `min(availability.validUntil, pricing.validUntil)`.
        public let deadline: BookingDeadline?

        public var isBookable: Bool { status == "BOOKABLE" }

        private enum CodingKeys: String, CodingKey { case partnerBookingRef, bookingRef, status, rejectionReasonCode, itemTotalPrice, bookingHoldInfo }
        private enum HoldKeys: String, CodingKey { case availability, pricing }
        private enum ValidityKeys: String, CodingKey { case validUntil }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            partnerBookingRef = container.flexibleString(.partnerBookingRef)
            bookingRef = try container.decode(String.self, forKey: .bookingRef)
            status = container.flexibleString(.status) ?? ""
            rejectionReasonCode = container.flexibleString(.rejectionReasonCode)
            itemTotalPrice = try? container.decode(ViatorPrice.self, forKey: .itemTotalPrice)
            let hold = try? container.nestedContainer(keyedBy: HoldKeys.self, forKey: .bookingHoldInfo)
            let expiries = [HoldKeys.availability, .pricing].compactMap { key -> Date? in
                let validity = try? hold?.nestedContainer(keyedBy: ValidityKeys.self, forKey: key)
                return ISO8601.date(from: validity?.flexibleString(.validUntil))
            }
            deadline = BookingDeadline(earliestOf: expiries)
        }
    }

    private enum CodingKeys: String, CodingKey { case cartRef, partnerCartRef, currency, items, totalHeldPrice, paymentSessionToken }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cartRef = try container.decode(String.self, forKey: .cartRef)
        partnerCartRef = container.flexibleString(.partnerCartRef)
        currency = container.flexibleString(.currency) ?? ""
        items = container.lossyArray(.items)
        totalHeldPrice = try? container.decode(ViatorPrice.self, forKey: .totalHeldPrice)
        paymentSessionToken = container.flexibleString(.paymentSessionToken)
    }
}

/// An answer to a booking question; `travelerNum` is 1-based and only set for `PER_TRAVELER`.
public struct ViatorAnswer: Sendable, Hashable, Codable {
    public let question: String
    public let answer: String
    public let unit: String?
    public let travelerNum: Int?

    public init(question: String, answer: String, unit: String? = nil, travelerNum: Int? = nil) {
        self.question = question
        self.answer = answer
        self.unit = unit
        self.travelerNum = travelerNum
    }

    /// A pickup at a location from `/locations/bulk`.
    public static func pickup(at reference: String) -> ViatorAnswer {
        ViatorAnswer(question: ViatorBookingQuestion.pickupPointId, answer: reference, unit: "LOCATION_REFERENCE")
    }

    /// No pickup: the traveller meets at the departure point.
    public static let meetAtDeparturePoint = ViatorAnswer(question: ViatorBookingQuestion.pickupPointId,
                                                          answer: "MEET_AT_DEPARTURE_POINT", unit: "LOCATION_REFERENCE")
}

/// What the customer filled in at checkout, sent with `cart/book`.
public struct ViatorBookerDetails: Sendable, Hashable {
    public let firstName: String
    public let lastName: String
    public let email: String
    public let phone: String
    public let answers: [ViatorAnswer]
    public let languageGuide: ViatorLanguageGuide?

    public init(firstName: String, lastName: String, email: String, phone: String,
                answers: [ViatorAnswer], languageGuide: ViatorLanguageGuide? = nil) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.answers = answers
        self.languageGuide = languageGuide
    }
}

struct ViatorBookRequest: Encodable {
    struct BookerInfo: Encodable { let firstName: String; let lastName: String }
    struct Communication: Encodable { let email: String; let phone: String }
    struct Item: Encodable {
        let bookingRef: String
        let bookingQuestionAnswers: [ViatorAnswer]
        let languageGuide: ViatorLanguageGuide?
    }
    struct AdditionalDetails: Encodable {
        struct Fraud: Encodable { let subChannelId: String; let voucherDeliveryType: String }
        let fraudPreventionDetails: Fraud
    }

    let cartRef: String
    let bookerInfo: BookerInfo
    let communication: Communication
    let items: [Item]
    let paymentToken: String
    let additionalBookingDetails: AdditionalDetails

    init(cartRef: String, bookingRef: String, details: ViatorBookerDetails, paymentToken: String, subChannelId: String) {
        self.cartRef = cartRef
        bookerInfo = BookerInfo(firstName: details.firstName, lastName: details.lastName)
        communication = Communication(email: details.email, phone: details.phone)
        items = [Item(bookingRef: bookingRef, bookingQuestionAnswers: details.answers, languageGuide: details.languageGuide)]
        self.paymentToken = paymentToken
        additionalBookingDetails = AdditionalDetails(fraudPreventionDetails: .init(subChannelId: subChannelId, voucherDeliveryType: "EMAIL_TO_CUSTOMER"))
    }
}

/// Viator's per-item booking status.
public enum ViatorBookingStatus: Sendable, Hashable {
    case confirmed
    case pending
    case rejected
    case failed
    case cancelled
    case other(String)

    init(_ raw: String?) {
        switch raw?.uppercased() {
        case "CONFIRMED": self = .confirmed
        case "PENDING", "ON_HOLD", "IN_PROGRESS": self = .pending
        case "REJECTED": self = .rejected
        case "FAILED": self = .failed
        case "CANCELLED", "CANCELED": self = .cancelled
        default: self = .other(raw ?? "")
        }
    }

    var recordStatus: BookingRecordStatus? {
        switch self {
        case .confirmed: return .confirmed
        case .pending: return .pending
        case .rejected, .failed: return .failed
        case .cancelled: return .cancelled
        case .other: return nil
        }
    }
}

/// A voucher link to show the customer.
public struct ViatorVoucher: Sendable, Hashable, Decodable {
    public let url: URL?
    public let format: String?
    public let type: String?

    private enum CodingKeys: String, CodingKey { case url, format, type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.flexibleString(.url).flatMap(URL.init(string:))
        format = container.flexibleString(.format)
        type = container.flexibleString(.type)
    }
}

/// One booked item, from `cart/book` or `bookings/status`.
public struct ViatorBookedItem: Sendable, Hashable, Decodable {
    public let bookingRef: String
    public let status: ViatorBookingStatus
    public let rawStatus: String?
    public let itemTotalPrice: ViatorPrice?
    /// The contractual policy for this booking; supersedes the listing's hint.
    public let cancellationPolicy: ViatorCancellationPolicy?
    public let voucher: ViatorVoucher?

    private enum CodingKeys: String, CodingKey { case bookingRef, status, itemTotalPrice, cancellationPolicy, voucherInfo }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookingRef = try container.decode(String.self, forKey: .bookingRef)
        rawStatus = container.flexibleString(.status)
        status = ViatorBookingStatus(rawStatus)
        itemTotalPrice = try? container.decode(ViatorPrice.self, forKey: .itemTotalPrice)
        cancellationPolicy = try? container.decode(ViatorCancellationPolicy.self, forKey: .cancellationPolicy)
        voucher = try? container.decode(ViatorVoucher.self, forKey: .voucherInfo)
    }
}

/// The answer to `POST /bookings/cart/book`.
public struct ViatorBookResult: Sendable, Hashable, Decodable {
    public let cartRef: String?
    public let currency: String?
    public let items: [ViatorBookedItem]
    public let voucher: ViatorVoucher?
    public let totalConfirmedPrice: ViatorPrice?
    /// Above zero when something still waits for the supplier.
    public let totalPendingPrice: ViatorPrice?

    private enum CodingKeys: String, CodingKey { case cartRef, currency, items, voucherInfo, totalConfirmedPrice, totalPendingPrice }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cartRef = container.flexibleString(.cartRef)
        currency = container.flexibleString(.currency)
        items = container.lossyArray(.items)
        voucher = try? container.decode(ViatorVoucher.self, forKey: .voucherInfo)
        totalConfirmedPrice = try? container.decode(ViatorPrice.self, forKey: .totalConfirmedPrice)
        totalPendingPrice = try? container.decode(ViatorPrice.self, forKey: .totalPendingPrice)
    }
}

/// `GET /bookings/{bookingRef}/cancel-quote`; show `refundAmount` before cancelling.
public struct ViatorCancelQuote: Sendable, Hashable, Decodable {
    public let bookingId: String
    public let itemPrice: Decimal?
    public let refundAmount: Decimal?
    public let refundPercentage: Decimal?
    public let currencyCode: String?
    public let status: String?

    private enum CodingKeys: String, CodingKey { case bookingId, refundDetails, status }
    private enum RefundKeys: String, CodingKey { case itemPrice, refundAmount, refundPercentage, currencyCode }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookingId = container.flexibleString(.bookingId) ?? ""
        status = container.flexibleString(.status)
        let refund = try? container.nestedContainer(keyedBy: RefundKeys.self, forKey: .refundDetails)
        itemPrice = refund?.flexibleDecimal(.itemPrice)
        refundAmount = refund?.flexibleDecimal(.refundAmount)
        refundPercentage = refund?.flexibleDecimal(.refundPercentage)
        currencyCode = refund?.flexibleString(.currencyCode)
    }
}

/// `POST /bookings/{bookingRef}/cancel`.
public struct ViatorCancellation: Sendable, Hashable, Decodable {
    public let bookingId: String
    /// Show it when the cancellation is declined.
    public let reason: String?
    public let status: String

    public var isAccepted: Bool { status.uppercased() == "ACCEPTED" }

    private enum CodingKeys: String, CodingKey { case bookingId, reason, status }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookingId = container.flexibleString(.bookingId) ?? ""
        reason = container.flexibleString(.reason)
        status = container.flexibleString(.status) ?? ""
    }
}

struct ViatorCancelRequest: Encodable {
    let reasonCode: String
}

struct ViatorStatusRequest: Encodable {
    let bookingRef: String
}

/// Viator's cancellation policy, with the refund window that applies now.
public struct ViatorCancellationPolicy: Sendable, Hashable, Decodable {

    public struct Window: Sendable, Hashable, Decodable {
        public let dayRangeMin: Int?
        public let dayRangeMax: Int?
        public let percentageRefundable: Decimal
        /// `nil` is open-ended.
        public let start: Date?
        /// `nil` is open-ended.
        public let end: Date?

        private enum CodingKeys: String, CodingKey { case dayRangeMin, dayRangeMax, percentageRefundable, startTimestamp, endTimestamp }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            dayRangeMin = container.flexibleInt(.dayRangeMin)
            dayRangeMax = container.flexibleInt(.dayRangeMax)
            percentageRefundable = container.flexibleDecimal(.percentageRefundable) ?? 0
            start = ISO8601.date(from: container.flexibleString(.startTimestamp))
            end = ISO8601.date(from: container.flexibleString(.endTimestamp))
        }

        public func contains(_ date: Date) -> Bool {
            (start.map { date >= $0 } ?? true) && (end.map { date < $0 } ?? true)
        }
    }

    /// What the checkout shows for the policy at a moment.
    public enum Summary: Sendable, Hashable {
        case allSalesFinal
        case freeCancellation(until: Date?, percentage: Decimal)
        case noRefund
    }

    public let type: String
    /// Free text, safe to display verbatim.
    public let description: String?
    public let cancelIfBadWeather: Bool
    public let cancelIfInsufficientTravelers: Bool
    public let refundEligibility: [Window]

    public func summary(at now: Date = Date()) -> Summary {
        if type.uppercased() == "ALL_SALES_FINAL" { return .allSalesFinal }
        guard let window = refundEligibility.first(where: { $0.contains(now) }), window.percentageRefundable > 0 else {
            return .noRefund
        }
        return .freeCancellation(until: window.end, percentage: window.percentageRefundable)
    }

    private enum CodingKeys: String, CodingKey { case type, description, cancelIfBadWeather, cancelIfInsufficientTravelers, refundEligibility }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = container.flexibleString(.type) ?? "STANDARD"
        description = container.flexibleString(.description)
        cancelIfBadWeather = container.flexibleBool(.cancelIfBadWeather) ?? false
        cancelIfInsufficientTravelers = container.flexibleBool(.cancelIfInsufficientTravelers) ?? false
        refundEligibility = container.lossyArray(.refundEligibility)
    }
}

struct ViatorErrorBody: Decodable {
    let code: String?
    let message: String?
    let trackingId: String?
}
