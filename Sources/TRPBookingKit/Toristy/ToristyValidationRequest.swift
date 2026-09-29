import Foundation

/// The `POST /bookingValidation` body.
public struct ToristyValidationRequest: Sendable, Hashable, Encodable {

    struct DirectBooking: Sendable, Hashable, Encodable {
        let mainContactDetails: [ToristyAnswer]
        let activityBookings: [ActivityBooking]
    }

    struct ActivityBooking: Sendable, Hashable, Encodable {
        let activityId: String
        let rateId: String
        let startTimeId: Int
        let date: String
        let pickup: Bool
        let pickupDescription: String?
        let pickupPlaceId: Int?
        let pickupAnswers: [ToristyAnswer]
        let dropoff: Bool
        let dropoffDescription: String?
        let dropoffPlaceId: Int?
        let dropoffAnswers: [ToristyAnswer]
        let passengers: [Passenger]
        let answers: [BookingAnswer]
    }

    struct Passenger: Sendable, Hashable, Encodable {
        let pricingCategoryId: String
        let passengerDetails: [ToristyAnswer]
        let answers: [ToristyAnswer]
        let extras: [ToristyExtraSelection]
    }

    /// Booking-level answers carry `values` as one string, unlike every other answer.
    struct BookingAnswer: Sendable, Hashable, Encodable {
        let questionId: String
        let values: String
    }

    let currency: String
    let directBooking: DirectBooking

    public init(selection: ToristySelection) {
        currency = selection.currency.uppercased()
        let booking = ActivityBooking(
            activityId: String(selection.serviceId),
            rateId: selection.rateId,
            startTimeId: selection.startTime.id,
            date: selection.validationDate,
            pickup: selection.pickup != nil,
            pickupDescription: selection.pickup?.description,
            pickupPlaceId: selection.pickup?.placeId,
            pickupAnswers: selection.pickup?.answers ?? [],
            dropoff: selection.dropoff != nil,
            dropoffDescription: selection.dropoff?.description,
            dropoffPlaceId: selection.dropoff?.placeId,
            dropoffAnswers: selection.dropoff?.answers ?? [],
            passengers: selection.passengers.map {
                Passenger(pricingCategoryId: $0.pricingCategoryId,
                          passengerDetails: $0.details,
                          answers: $0.answers,
                          extras: $0.extras.filter { $0.quantity > 0 })
            },
            answers: selection.bookingAnswers.map { BookingAnswer(questionId: $0.questionId, values: $0.values.joined(separator: ", ")) }
        )
        directBooking = DirectBooking(mainContactDetails: selection.mainContact, activityBookings: [booking])
    }

    private enum CodingKeys: String, CodingKey { case currency, directBooking }
}

/// The `POST /bookingConfirmation` body: a record of the charge already made.
struct ToristyConfirmationRequest: Sendable, Encodable {

    struct TransactionDetails: Sendable, Encodable {
        let transactionDate: String
        let cardBrand: String
        let last4: String
    }

    let transactionDetails: TransactionDetails
    let currency: String
    let amount: Decimal

    init(receipt: PaymentReceipt, amount: Decimal, currency: String) {
        transactionDetails = TransactionDetails(
            transactionDate: ISO8601.string(from: receipt.paidAt),
            cardBrand: receipt.cardBrand ?? "Card",
            last4: receipt.last4 ?? "0000"
        )
        self.currency = currency.uppercased()
        self.amount = amount
    }
}

/// The `POST /bookingcancel` body.
struct ToristyCancelRequest: Sendable, Encodable {
    let note: String?
    let notify: Bool
}
