import Foundation

struct MobileServerDetailRoute: Identifiable, Equatable {
    enum Kind: Equatable {
        case server
        case terminal
        case folder(String?)
        case automation(String)
    }

    let id = UUID()
    let profileId: String
    let kind: Kind
}
