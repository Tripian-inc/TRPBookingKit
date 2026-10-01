import Foundation

/// Builders for the blocks the local flows share.
enum LocalBlocks {
    typealias BC = BookingContract

    static let continueAction = BC.PrimaryAction(title: "Continue")
    static let paymentAction = BC.PrimaryAction(title: "Continue to payment")

    static func text(_ id: String, _ label: String, autofill: String? = nil, hint: String? = nil, scope: BC.FieldScope = .booking,
                     traveler: Int? = nil, defaults: StepAnswers) -> BC.Block {
        .field(.text(BC.FieldSpec(id: id, label: label, hint: hint, required: true, scope: .init(scope), travelerIndex: traveler,
                                  defaultValue: defaults.string(id), autofill: autofill)))
    }

    static func date(_ id: String, _ label: String, hint: String? = nil, traveler: Int?, defaults: StepAnswers) -> BC.Block {
        .field(.date(BC.FieldSpec(id: id, label: label, hint: hint, required: true, scope: .init(.traveler), travelerIndex: traveler,
                                  defaultValue: defaults.string(id))))
    }

    /// First and last name, email and phone of the lead traveler under `prefix`.
    static func contact(_ prefix: String, defaults: StepAnswers) -> [BC.Block] {
        [
            text("\(prefix).firstName", "First name", autofill: "givenName", defaults: defaults),
            text("\(prefix).lastName", "Last name", autofill: "familyName", defaults: defaults),
            .field(.email(BC.FieldSpec(id: "\(prefix).email", label: "Email", required: true, scope: .init(.booking),
                                       defaultValue: defaults.string("\(prefix).email"), autofill: "email"))),
            .field(.phone(BC.FieldSpec(id: "\(prefix).phone", label: "Phone", required: true, scope: .init(.booking),
                                       defaultValue: defaults.string("\(prefix).phone"), autofill: "tel")))
        ]
    }

    static func contactErrors(_ prefix: String, in answers: BC.Answers) -> [BC.ErrorData.FieldError] {
        var errors = LocalValidation.required([("\(prefix).firstName", "Enter a first name."),
                                               ("\(prefix).lastName", "Enter a last name."),
                                               ("\(prefix).email", "Enter an email address."),
                                               ("\(prefix).phone", "Enter a phone number.")], in: answers)
        if let email = LocalValidation.email("\(prefix).email", in: answers) { errors.append(email) }
        return errors
    }

    static func terms(_ text: String, link: BC.ConsentBlock.Link) -> BC.Block {
        .consent(BC.ConsentBlock(id: "terms", text: text, links: [link], required: true))
    }

    static func notice(_ id: String, _ tone: BC.NoticeTone, _ text: String, skippable: Bool = true) -> BC.Block {
        .notice(BC.NoticeBlock(id: id, onUnsupported: skippable ? .init(.skip) : nil, tone: .init(tone), text: text))
    }

    static func step(_ id: String, _ title: String, subtitle: String? = nil, index: Int, count: Int?, blocks: [BC.Block],
                     primary: BC.PrimaryAction = continueAction) -> BC.Step {
        BC.Step(id: id, title: title, subtitle: subtitle, progress: BC.Step.Progress(index: index, count: count), blocks: blocks,
                primaryAction: primary)
    }

    static let confirmedResult = (title: "Your booking is confirmed", message: "Your tickets have also been sent to your email address.")
}
