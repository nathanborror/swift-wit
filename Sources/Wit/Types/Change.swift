import Foundation

public struct Change: Sendable {
    public let path: String
    public let hash: String?
    public let kind: Kind

    public enum Kind: Sendable {
        case added
        case modified
        case deleted
    }
}
