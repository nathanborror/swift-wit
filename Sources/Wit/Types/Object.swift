import Foundation

public struct Object {
    public let kind: Kind
    public let content: Data
    public let size: Int

    public enum Kind: String {
        case blob = "blob"
        case tree = "tree"
        case commit = "commit"
    }
}
