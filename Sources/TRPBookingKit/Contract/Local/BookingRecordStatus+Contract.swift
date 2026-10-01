import Foundation

extension BookingRecordStatus {
    /// The contract status of a record.
    ///
    /// Two mappings are approximations the contract has no exact status for: `needsRefund` maps to
    /// `rejected` although the customer was charged and awaits a refund, and `refunded` maps to
    /// `cancelled` although the booking was never confirmed.
    public var contractStatus: BookingContract.BookingStatus {
        switch self {
        case .held: return .onHold
        case .charged, .pending: return .pending
        case .confirmed: return .confirmed
        case .needsRefund, .failed: return .rejected
        case .refunded, .cancelled: return .cancelled
        case .expired: return .expired
        }
    }
}
