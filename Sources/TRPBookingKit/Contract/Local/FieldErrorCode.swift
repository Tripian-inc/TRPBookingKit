import Foundation

/// The reasons the local flows reject an answer; the raw value is sent as `FieldError.code`.
enum FieldErrorCode: String, CaseIterable {
    case productNotBookable = "product_not_bookable"
    case missingDate = "missing_date"
    case missingTime = "missing_time"
    case missingRate = "missing_rate"
    case missingOption = "missing_option"
    case missingSeats = "missing_seats"
    case missingTickets = "missing_tickets"
    case invalidUnits = "invalid_units"
    case invalidTicketQuantity = "invalid_ticket_quantity"
    case requiredFirstName = "required_first_name"
    case requiredLastName = "required_last_name"
    case requiredEmail = "required_email"
    case invalidEmail = "invalid_email"
    case requiredPhone = "required_phone"
    case requiredTravelerName = "required_traveler_name"
    case requiredTravelerBirthDate = "required_traveler_birth_date"
    case requiredBillingAddress = "required_billing_address"
    case requiredBillingCity = "required_billing_city"
    case requiredBillingPostalCode = "required_billing_postal_code"
    case requiredBillingCountry = "required_billing_country"
    case requiredBillingState = "required_billing_state"
    case requiredTerms = "required_terms"
    case missingPaymentToken = "missing_payment_token"
    case invalidAnswer = "invalid_answer"

    /// The English text shown when the client has no translation for the code.
    var message: String {
        switch self {
        case .productNotBookable: return "This product cannot be booked in the app."
        case .missingDate: return "Choose one of the available dates."
        case .missingTime: return "Choose a start time."
        case .missingRate: return "Choose a rate."
        case .missingOption: return "Choose a tour and time."
        case .missingSeats: return "Choose available seats."
        case .missingTickets: return "Choose available tickets."
        case .invalidUnits: return "Choose a valid number of travelers."
        case .invalidTicketQuantity: return "Choose a quantity these tickets are sold in."
        case .requiredFirstName: return "Enter a first name."
        case .requiredLastName: return "Enter a last name."
        case .requiredEmail: return "Enter an email address."
        case .invalidEmail: return "Enter a valid email address."
        case .requiredPhone: return "Enter a phone number."
        case .requiredTravelerName: return "Enter the traveler's full name."
        case .requiredTravelerBirthDate: return "Enter the traveler's date of birth."
        case .requiredBillingAddress: return "Enter the billing address."
        case .requiredBillingCity: return "Enter the city."
        case .requiredBillingPostalCode: return "Enter the postal code."
        case .requiredBillingCountry: return "Choose the country."
        case .requiredBillingState: return "Choose the state."
        case .requiredTerms: return "Please accept the terms to continue."
        case .missingPaymentToken: return "The payment form returned no token."
        case .invalidAnswer: return "Check your answers and try again."
        }
    }
}

extension BookingContract.ErrorData.FieldError {

    /// A field error carrying `code`, with `message` overriding the code's English text when the reason needs detail.
    static func local(_ code: FieldErrorCode, field: String, message: String? = nil) -> Self {
        Self(field: field, code: code.rawValue, message: message ?? code.message)
    }
}
