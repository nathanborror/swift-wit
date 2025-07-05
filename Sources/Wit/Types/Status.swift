import Foundation

public struct Status {
    public let modified: [String]
    public let added: [String]
    public let deleted: [String]

    public var hasChanges: Bool {
        !modified.isEmpty || !added.isEmpty || !deleted.isEmpty
    }
}
