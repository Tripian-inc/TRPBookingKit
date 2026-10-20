import Foundation

/// A Ticket Evolution event: one fixed date and time, no date picker and no traveller mix.
public struct VictoryEvent: Sendable, Hashable, Decodable {

    public struct Venue: Sendable, Hashable {
        public let id: Int?
        public let name: String?
        /// May be `nil`; guard before formatting a local time.
        public let timeZone: TimeZone?
        public let latitude: Double?
        public let longitude: Double?
        public let address: Address?
    }

    /// The venue's postal address as TE lists it.
    public struct Address: Sendable, Hashable {
        public let streetAddress: String?
        public let extendedAddress: String?
        public let locality: String?
        public let region: String?
        public let postalCode: String?
        public let countryCode: String?

        public init(streetAddress: String? = nil, extendedAddress: String? = nil, locality: String? = nil, region: String? = nil,
                    postalCode: String? = nil, countryCode: String? = nil) {
            self.streetAddress = streetAddress
            self.extendedAddress = extendedAddress
            self.locality = locality
            self.region = region
            self.postalCode = postalCode
            self.countryCode = countryCode
        }

        /// The non-empty parts joined by ", ", e.g. "226 W 46th St, New York, NY, 10036, US".
        public var formatted: String {
            [streetAddress, extendedAddress, locality, region, postalCode, countryCode]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
    }

    /// A performer appearing at the event; `isPrimary` marks the headliner.
    public struct Performer: Sendable, Hashable {
        public let id: Int
        public let name: String?
        public let isPrimary: Bool

        public init(id: Int, name: String?, isPrimary: Bool) {
            self.id = id
            self.name = name
            self.isPrimary = isPrimary
        }
    }

    /// The event's TE category, such as "Broadway".
    public struct Category: Sendable, Hashable {
        public let id: Int
        public let name: String?

        public init(id: Int, name: String?) {
            self.id = id
            self.name = name
        }
    }

    public let id: Int
    public let name: String?
    public let occursAt: Date?
    /// The venue's wall-clock time as TE sends it, `yyyy-MM-dd'T'HH:mm:ss` with no offset.
    public let occursAtLocal: String?
    /// `true` when the start time is not announced yet: show "time TBA", never `00:00`.
    public let isTimeToBeAnnounced: Bool
    public let state: String?
    public let availableCount: Int?
    public let venue: Venue?
    public let configurationId: Int?
    /// Static seat-map images, the practical option on a phone.
    public let seatingChartMedium: URL?
    public let seatingChartLarge: URL?
    /// In the order TE lists them; empty when TE sends none.
    public let performers: [Performer]
    public let category: Category?

    private enum CodingKeys: String, CodingKey {
        case id, name, state, tbd, venue, configuration, performances, category
        case occursAt = "occurs_at", occursAtLocal = "occurs_at_local", availableCount = "available_count"
    }
    private enum VenueKeys: String, CodingKey { case id, name, address, timeZone = "time_zone" }
    private enum AddressKeys: String, CodingKey {
        case latitude, longitude, locality, region
        case streetAddress = "street_address", extendedAddress = "extended_address", postalCode = "postal_code"
        case countryCode = "country_code"
    }
    private enum CategoryKeys: String, CodingKey { case id, name }
    private enum ConfigurationKeys: String, CodingKey { case id, seatingChart = "seating_chart" }
    private enum ChartKeys: String, CodingKey { case medium, large }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleInt(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: container.codingPath, debugDescription: "event id"))
        }
        self.id = id
        name = container.flexibleString(.name)
        occursAt = ISO8601.date(from: container.flexibleString(.occursAt))
        occursAtLocal = container.flexibleString(.occursAtLocal)
        isTimeToBeAnnounced = container.flexibleBool(.tbd) ?? false
        state = container.flexibleString(.state)
        availableCount = container.flexibleInt(.availableCount)

        if let venueContainer = try? container.nestedContainer(keyedBy: VenueKeys.self, forKey: .venue) {
            let address = try? venueContainer.nestedContainer(keyedBy: AddressKeys.self, forKey: .address)
            venue = Venue(id: venueContainer.flexibleInt(.id),
                          name: venueContainer.flexibleString(.name),
                          timeZone: venueContainer.flexibleString(.timeZone).flatMap(TimeZone.init(identifier:)),
                          latitude: address?.flexibleDecimal(.latitude).map { NSDecimalNumber(decimal: $0).doubleValue },
                          longitude: address?.flexibleDecimal(.longitude).map { NSDecimalNumber(decimal: $0).doubleValue },
                          address: address.flatMap(Self.postalAddress))
        } else {
            venue = nil
        }

        let configuration = try? container.nestedContainer(keyedBy: ConfigurationKeys.self, forKey: .configuration)
        configurationId = configuration?.flexibleInt(.id)
        let chart = try? configuration?.nestedContainer(keyedBy: ChartKeys.self, forKey: .seatingChart)
        seatingChartMedium = chart?.flexibleString(.medium).flatMap(URL.init(string:))
        seatingChartLarge = chart?.flexibleString(.large).flatMap(URL.init(string:))

        performers = container.lossyArray(.performances).map { (performance: VictoryPerformance) in performance.performer }
        let category = try? container.nestedContainer(keyedBy: CategoryKeys.self, forKey: .category)
        self.category = category.flatMap { keyed in keyed.flexibleInt(.id).map { Category(id: $0, name: keyed.flexibleString(.name)) } }
    }

    private static func postalAddress(_ container: KeyedDecodingContainer<AddressKeys>) -> Address? {
        let address = Address(streetAddress: container.flexibleString(.streetAddress),
                              extendedAddress: container.flexibleString(.extendedAddress),
                              locality: container.flexibleString(.locality), region: container.flexibleString(.region),
                              postalCode: container.flexibleString(.postalCode), countryCode: container.flexibleString(.countryCode))
        return address.formatted.isEmpty ? nil : address
    }
}

/// One entry of TE's `performances`: `{ "performer": { "id", "name" }, "primary" }`.
private struct VictoryPerformance: Decodable {
    let performer: VictoryEvent.Performer

    private enum CodingKeys: String, CodingKey { case performer, primary }
    private enum PerformerKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.nestedContainer(keyedBy: PerformerKeys.self, forKey: .performer)
        guard let id = nested.flexibleInt(.id) else {
            throw DecodingError.keyNotFound(PerformerKeys.id, .init(codingPath: nested.codingPath, debugDescription: "performer id"))
        }
        performer = VictoryEvent.Performer(id: id, name: nested.flexibleString(.name), isPrimary: container.flexibleBool(.primary) ?? false)
    }
}

/// `GET /v9/events`: `{ "events": [...] }`, with a missing key read as no events.
struct VictoryEventsResponse: Decodable {
    let events: [VictoryEvent]

    private enum CodingKeys: String, CodingKey { case events }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = container.lossyArray(.events)
    }
}

/// The events near a point within a time window, as TE's `GET /v9/events` takes them.
public struct VictoryEventSearch: Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    /// Inclusive start of the window (`occurs_at.gte`).
    public var from: Date
    /// Exclusive end of the window (`occurs_at.lt`).
    public var to: Date
    public var categoryId: Int?
    public var perPage: Int

    public init(latitude: Double, longitude: Double, from: Date, to: Date, categoryId: Int? = nil, perPage: Int = 100) {
        self.latitude = latitude
        self.longitude = longitude
        self.from = from
        self.to = to
        self.categoryId = categoryId
        self.perPage = perPage
    }

    /// `lat`, `lon`, `occurs_at.gte`, `occurs_at.lt`, `category_id` when set and `per_page`, times in UTC.
    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "lat", value: Self.coordinate(latitude)),
                     URLQueryItem(name: "lon", value: Self.coordinate(longitude)),
                     URLQueryItem(name: "occurs_at.gte", value: LocalFormat.iso(from)),
                     URLQueryItem(name: "occurs_at.lt", value: LocalFormat.iso(to))]
        if let categoryId { items.append(URLQueryItem(name: "category_id", value: String(categoryId))) }
        items.append(URLQueryItem(name: "per_page", value: String(perPage)))
        return items
    }

    /// A coordinate with six fixed decimals, never in exponent form, e.g. `-73.986600`.
    static func coordinate(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// A block of seats (section + row) sold together, in the quantities its `splits` allow.
public struct VictoryTicketGroup: Sendable, Hashable, Decodable, Identifiable {
    public let id: Int
    public let section: String?
    public let row: String?
    /// Lowercased `tevo_section_name`, the key the seat map uses.
    public let seatMapSection: String?
    public let quantity: Int
    public let availableQuantity: Int
    public let splits: [Int]
    /// The unit price to show, in USD.
    public let retailPrice: Decimal?
    public let retailPriceInclusive: Decimal?
    /// The broker's cost; required by the order, never shown.
    public let wholesalePrice: Decimal?
    public let serviceFee: Decimal?
    public let faceValue: Decimal?
    public let format: String?
    public let type: String?
    public let isEticket: Bool
    public let isInstantDelivery: Bool
    public let isInHand: Bool
    /// When the tickets will be in hand; must be shown to the customer.
    public let inHandOn: BookingDate?
    /// Seller constraints such as an obstructed view; must be shown to the customer.
    public let publicNotes: String?
    public let isWheelchairAccessible: Bool

    private enum CodingKeys: String, CodingKey {
        case id, section, row, quantity, splits, format, type, eticket, wheelchair
        case tevoSectionName = "tevo_section_name", availableQuantity = "available_quantity"
        case retailPrice = "retail_price", retailPriceInclusive = "retail_price_inclusive"
        case wholesalePrice = "wholesale_price", serviceFee = "service_fee", faceValue = "face_value"
        case instantDelivery = "instant_delivery", inHand = "in_hand", inHandOn = "in_hand_on", publicNotes = "public_notes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleInt(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: container.codingPath, debugDescription: "ticket group id"))
        }
        self.id = id
        section = container.flexibleString(.section)
        row = container.flexibleString(.row)
        seatMapSection = container.flexibleString(.tevoSectionName)?.lowercased()
        quantity = container.flexibleInt(.quantity) ?? 0
        availableQuantity = container.flexibleInt(.availableQuantity) ?? quantity
        splits = container.flexibleIntArray(.splits)
        retailPrice = container.flexibleDecimal(.retailPrice)
        retailPriceInclusive = container.flexibleDecimal(.retailPriceInclusive)
        wholesalePrice = container.flexibleDecimal(.wholesalePrice)
        serviceFee = container.flexibleDecimal(.serviceFee)
        faceValue = container.flexibleDecimal(.faceValue)
        format = container.flexibleString(.format)
        type = container.flexibleString(.type)
        isEticket = container.flexibleBool(.eticket) ?? false
        isInstantDelivery = container.flexibleBool(.instantDelivery) ?? false
        isInHand = container.flexibleBool(.inHand) ?? false
        inHandOn = container.flexibleString(.inHandOn).flatMap { BookingDate(String($0.prefix(10))) }
        publicNotes = container.flexibleString(.publicNotes).flatMap { $0.isEmpty ? nil : $0 }
        isWheelchairAccessible = container.flexibleBool(.wheelchair) ?? false
    }

    /// The only quantities this group can be sold in, smallest first.
    public var sellableQuantities: [Int] {
        Array(Set(splits.filter { $0 > 0 && $0 <= availableQuantity })).sorted()
    }

    /// Delivered by email, so no shipping address, courier or P.O. Box rules are involved.
    public var isDigital: Bool {
        isEticket || isInstantDelivery || (format.map { $0.lowercased() != "physical" } ?? false)
    }

    public func total(quantity: Int) -> Decimal? {
        retailPrice.map { $0 * Decimal(quantity) }
    }
}

struct VictoryListingsResponse: Decodable {
    let totalEntries: Int?
    let ticketGroups: [VictoryTicketGroup]

    private enum CodingKeys: String, CodingKey { case totalEntries = "total_entries", ticketGroups = "ticket_groups" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalEntries = container.flexibleInt(.totalEntries)
        ticketGroups = container.lossyArray(.ticketGroups)
    }
}

/// The buyer, created as a TE client before the order.
public struct VictoryBuyer: Sendable, Hashable {

    public struct Address: Sendable, Hashable {
        public var streetAddress: String
        public var extendedAddress: String?
        public var locality: String
        public var region: String?
        public var postalCode: String
        /// ISO 3166-1 alpha-2.
        public var countryCode: String

        public init(streetAddress: String, extendedAddress: String? = nil, locality: String, region: String? = nil,
                    postalCode: String, countryCode: String) {
            self.streetAddress = streetAddress
            self.extendedAddress = extendedAddress
            self.locality = locality
            self.region = region
            self.postalCode = postalCode
            self.countryCode = countryCode
        }
    }

    public var name: String
    public var email: String
    /// National number without the country code.
    public var phoneNumber: String?
    public var phoneCountryCode: String?
    /// Billing address, required by the card payment.
    public var billingAddress: Address

    public init(name: String, email: String, phoneNumber: String? = nil, phoneCountryCode: String? = nil, billingAddress: Address) {
        self.name = name
        self.email = email
        self.phoneNumber = phoneNumber
        self.phoneCountryCode = phoneCountryCode
        self.billingAddress = billingAddress
    }
}

struct VictoryClientRequest: Encodable {

    struct Client: Encodable {
        let name: String
        let officeId: Int?
        let emailAddresses: [Email]
        let phoneNumbers: [Phone]
        let addresses: [Address]

        private enum CodingKeys: String, CodingKey {
            case name, officeId = "office_id", emailAddresses = "email_addresses", phoneNumbers = "phone_numbers", addresses
        }
    }

    struct Email: Encodable {
        let address: String
        let label = "home"
        let isPrimary = true

        private enum CodingKeys: String, CodingKey { case address, label, isPrimary = "is_primary" }
    }

    struct Phone: Encodable {
        let number: String
        let countryCode: String?
        let label = "mobile"
        let isPrimary = true

        private enum CodingKeys: String, CodingKey { case number, countryCode = "country_code", label, isPrimary = "is_primary" }
    }

    struct Address: Encodable {
        let streetAddress: String
        let extendedAddress: String?
        let locality: String
        let region: String?
        let postalCode: String
        let countryCode: String
        let label = "home"
        let isPrimary = true

        private enum CodingKeys: String, CodingKey {
            case streetAddress = "street_address", extendedAddress = "extended_address", locality, region
            case postalCode = "postal_code", countryCode = "country_code", label, isPrimary = "is_primary"
        }
    }

    let clients: [Client]

    init(buyer: VictoryBuyer, officeId: Int?) {
        let address = buyer.billingAddress
        clients = [Client(
            name: buyer.name,
            officeId: officeId,
            emailAddresses: [Email(address: buyer.email)],
            phoneNumbers: buyer.phoneNumber.map { [Phone(number: $0, countryCode: buyer.phoneCountryCode)] } ?? [],
            addresses: [Address(streetAddress: address.streetAddress, extendedAddress: address.extendedAddress,
                                locality: address.locality, region: address.region, postalCode: address.postalCode,
                                countryCode: address.countryCode.uppercased())]
        )]
    }
}

/// The TE client created for a buyer, with the ids the order refers to.
public struct VictoryClient: Sendable, Hashable, Decodable {
    public let id: Int
    public let emailAddressId: Int?
    public let addressId: Int?
    public let phoneNumberId: Int?

    private enum CodingKeys: String, CodingKey {
        case id, emailAddresses = "email_addresses", addresses, phoneNumbers = "phone_numbers"
    }

    private struct Record: Decodable {
        let id: Int?
        private enum CodingKeys: String, CodingKey { case id }
        init(from decoder: Decoder) throws {
            id = try decoder.container(keyedBy: CodingKeys.self).flexibleInt(.id)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleInt(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: container.codingPath, debugDescription: "client id"))
        }
        self.id = id
        emailAddressId = container.lossyArray(.emailAddresses).compactMap { (record: Record) in record.id }.first
        addressId = container.lossyArray(.addresses).compactMap { (record: Record) in record.id }.first
        phoneNumberId = container.lossyArray(.phoneNumbers).compactMap { (record: Record) in record.id }.first
    }
}

struct VictoryClientsResponse: Decodable {
    let clients: [VictoryClient]

    private enum CodingKeys: String, CodingKey { case clients }

    init(from decoder: Decoder) throws {
        clients = try decoder.container(keyedBy: CodingKeys.self).lossyArray(.clients)
    }
}

struct VictoryTaxQuoteRequest: Encodable {

    struct Quote: Encodable {
        let ticketGroupId: Int
        let quantity: Int
        let retail: Retail

        private enum CodingKeys: String, CodingKey { case ticketGroupId = "ticket_group_id", quantity, retail }
    }

    struct Retail: Encodable {
        let price: Decimal
        let shipping: Decimal
        let serviceFee: Decimal
        let additionalExpense: Decimal
        let discount: Decimal

        private enum CodingKeys: String, CodingKey {
            case price, shipping, serviceFee = "service_fee", additionalExpense = "additional_expense", discount
        }
    }

    let taxQuote: Quote

    private enum CodingKeys: String, CodingKey { case taxQuote = "tax_quote" }

    init(group: VictoryTicketGroup, quantity: Int) {
        taxQuote = Quote(ticketGroupId: group.id, quantity: quantity,
                         retail: Retail(price: group.retailPrice ?? 0, shipping: 0, serviceFee: group.serviceFee ?? 0,
                                        additionalExpense: 0, discount: 0))
    }
}

/// Tax for a ticket group and quantity; `retailTaxAmount` and `signature` go into the order together.
public struct VictoryTaxQuote: Sendable, Hashable, Decodable {
    public let id: String?
    public let signature: String?
    public let retailTaxAmount: Decimal?
    public let wholesaleTaxAmount: Decimal?
    public let expiresAt: Date?

    private enum RootKeys: String, CodingKey { case taxQuote = "tax_quote" }
    private enum CodingKeys: String, CodingKey {
        case id, signature, retailTaxAmount = "retail_tax_amount", wholesaleTaxAmount = "wholesale_tax_amount", expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let container = try (try? root.nestedContainer(keyedBy: CodingKeys.self, forKey: .taxQuote)) ?? decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(.id)
        signature = container.flexibleString(.signature)
        retailTaxAmount = container.flexibleDecimal(.retailTaxAmount)
        wholesaleTaxAmount = container.flexibleDecimal(.wholesaleTaxAmount)
        expiresAt = ISO8601.date(from: container.flexibleString(.expiresAt))
    }

    /// Whether the pair can go into an order: TE takes both or neither.
    public var isUsable: Bool { signature != nil && retailTaxAmount != nil }

    public func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

/// What `POST /v10/orders` needs; built by `VictoryCheckout`.
public struct VictoryOrderRequest: Sendable, Hashable, Encodable {

    struct TicketGroup: Sendable, Hashable, Encodable {
        let id: Int
        let price: Decimal
        let quantity: Int
        let wholesalePrice: Decimal

        private enum CodingKeys: String, CodingKey { case id, price, quantity, wholesalePrice = "wholesale_price" }
    }

    struct Delivery: Sendable, Hashable, Encodable {
        let type = "Eticket"
        let emailAddressId: Int
        let cost: Decimal = 0

        private enum CodingKeys: String, CodingKey { case type, emailAddressId = "email_address_id", cost }
    }

    struct Payment: Sendable, Hashable, Encodable {
        let type = "credit_card"
        let token: String
        let addressId: Int

        private enum CodingKeys: String, CodingKey { case type, token, addressId = "address_id" }
    }

    struct Order: Sendable, Hashable, Encodable {
        let clientId: Int
        let ticketGroup: TicketGroup
        let delivery: Delivery
        let payments: [Payment]
        let tax: Decimal?
        let taxSignature: String?
        let serviceFee: Decimal
        let shipping: Decimal = 0
        let discount: Decimal = 0
        let reference: String
        let sessionId: String?

        private enum CodingKeys: String, CodingKey {
            case clientId = "client_id", ticketGroup = "ticket_group", delivery, payments, tax
            case taxSignature = "tax_signature", serviceFee = "service_fee", shipping, discount, reference, sessionId = "session_id"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(clientId, forKey: .clientId)
            try container.encode(ticketGroup, forKey: .ticketGroup)
            try container.encode(delivery, forKey: .delivery)
            try container.encode(payments, forKey: .payments)
            if let tax, let taxSignature {
                try container.encode(tax, forKey: .tax)
                try container.encode(taxSignature, forKey: .taxSignature)
            }
            try container.encode(serviceFee, forKey: .serviceFee)
            try container.encode(shipping, forKey: .shipping)
            try container.encode(discount, forKey: .discount)
            try container.encode(reference, forKey: .reference)
            try container.encodeIfPresent(sessionId, forKey: .sessionId)
        }
    }

    let order: Order

    init(client: VictoryClient, group: VictoryTicketGroup, quantity: Int, paymentToken: String,
         taxQuote: VictoryTaxQuote?, reference: String, sessionId: String?) throws {
        guard let emailAddressId = client.emailAddressId, let addressId = client.addressId else {
            throw BookingError.rejected("The buyer's email or billing address was not created.")
        }
        guard let price = group.retailPrice, let wholesale = group.wholesalePrice else {
            throw BookingError.rejected("These tickets have no price.")
        }
        let usableTax = taxQuote?.isUsable == true ? taxQuote : nil
        order = Order(clientId: client.id,
                      ticketGroup: TicketGroup(id: group.id, price: price, quantity: quantity, wholesalePrice: wholesale),
                      delivery: Delivery(emailAddressId: emailAddressId),
                      payments: [Payment(token: paymentToken, addressId: addressId)],
                      tax: usableTax?.retailTaxAmount,
                      taxSignature: usableTax?.signature,
                      serviceFee: group.serviceFee ?? 0,
                      reference: reference,
                      sessionId: sessionId)
    }
}

/// An order's state as TE names it.
public enum VictoryOrderState: Sendable, Hashable {
    case pending
    case accepted
    case completed
    case rejected
    case cancelled
    case other(String)

    init(_ raw: String?) {
        switch raw?.lowercased() {
        case "pending", "open": self = .pending
        case "accepted": self = .accepted
        case "completed", "shipped", "delivered": self = .completed
        case "rejected": self = .rejected
        case "canceled", "cancelled", "voided": self = .cancelled
        case let other: self = .other(other ?? "")
        }
    }

    var recordStatus: BookingRecordStatus? {
        switch self {
        case .pending: return .pending
        case .accepted, .completed: return .confirmed
        case .rejected: return .failed
        case .cancelled: return .cancelled
        case .other: return nil
        }
    }
}

/// A placed order.
public struct VictoryOrder: Sendable, Hashable, Decodable {

    public struct Item: Sendable, Hashable {
        public let quantity: Int?
        public let price: Decimal?
        public let section: String?
        public let row: String?
        /// Known only once the order is placed.
        public let seats: [Int]
        public let isEticketAvailable: Bool
    }

    public let id: String
    public let state: VictoryOrderState
    public let rawState: String?
    public let total: Decimal?
    public let subtotal: Decimal?
    public let tax: Decimal?
    public let serviceFee: Decimal?
    public let items: [Item]
    public let url: URL?
    public let reference: String?

    private enum CodingKeys: String, CodingKey {
        case id, state, total, subtotal, tax, items, url, reference, serviceFee = "service_fee"
    }
    private enum ItemKeys: String, CodingKey {
        case quantity, price, ticketGroup = "ticket_group", eticketAvailable = "eticket_available"
    }
    private enum GroupKeys: String, CodingKey { case section, row, seats }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexibleString(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: container.codingPath, debugDescription: "order id"))
        }
        self.id = id
        rawState = container.flexibleString(.state)
        state = VictoryOrderState(rawState)
        total = container.flexibleDecimal(.total)
        subtotal = container.flexibleDecimal(.subtotal)
        tax = container.flexibleDecimal(.tax)
        serviceFee = container.flexibleDecimal(.serviceFee)
        url = container.flexibleString(.url).flatMap(URL.init(string:))
        reference = container.flexibleString(.reference)

        var parsed: [Item] = []
        if var list = try? container.nestedUnkeyedContainer(forKey: .items) {
            while !list.isAtEnd {
                guard let item = try? list.nestedContainer(keyedBy: ItemKeys.self) else {
                    _ = try? list.decode(FlexibleSkip.self)
                    continue
                }
                let group = try? item.nestedContainer(keyedBy: GroupKeys.self, forKey: .ticketGroup)
                parsed.append(Item(quantity: item.flexibleInt(.quantity),
                                   price: item.flexibleDecimal(.price),
                                   section: group?.flexibleString(.section),
                                   row: group?.flexibleString(.row),
                                   seats: group?.flexibleIntArray(.seats) ?? [],
                                   isEticketAvailable: item.flexibleBool(.eticketAvailable) ?? false))
            }
        }
        items = parsed
    }
}

struct VictoryOrdersResponse: Decodable {
    let orders: [VictoryOrder]

    private enum CodingKeys: String, CodingKey { case orders }

    init(from decoder: Decoder) throws {
        orders = try decoder.container(keyedBy: CodingKeys.self).lossyArray(.orders)
    }
}

private struct FlexibleSkip: Decodable {}

struct VictoryErrorBody: Decodable {
    let error: String?
    let message: String?
    let code: String?

    private enum CodingKeys: String, CodingKey { case error, message, code, errors }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let errors = (try? container.decode([String].self, forKey: .errors)) ?? []
        error = container.flexibleString(.error) ?? errors.first
        message = container.flexibleString(.message) ?? (errors.isEmpty ? nil : errors.joined(separator: "\n"))
        code = container.flexibleString(.code)
    }
}
