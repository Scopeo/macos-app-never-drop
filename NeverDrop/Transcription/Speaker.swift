enum Speaker: Sendable, Equatable {
    case you
    case others
    case identified(String)

    var displayLabel: String {
        switch self {
        case .you: "You"
        case .others: "Others"
        case .identified(let id): "Speaker \(id)"
        }
    }
}
