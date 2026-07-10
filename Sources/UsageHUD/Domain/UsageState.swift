import Foundation

enum UsageState: Equatable, Sendable {
    case connecting
    case signedOut
    case unavailable(message: String)
    case empty
    case current([QuotaSnapshot])
    case stale([QuotaSnapshot], since: Date)
}
