enum Speaker: Sendable, Equatable {
    case you
    case identified(String)

    func label(userName: String) -> String {
        switch self {
        case .you: userName.isEmpty ? "You" : userName
        case .identified(let id): "Speaker \(id)"
        }
    }
}
