import Foundation

public struct Status {
    public var modified: [String]
    public var added: [String]
    public var deleted: [String]

    public var hasChanges: Bool {
        !modified.isEmpty || !added.isEmpty || !deleted.isEmpty
    }

    public init(modified: [String] = [], added: [String] = [], deleted: [String] = []) {
        self.modified = modified
        self.added = added
        self.deleted = deleted
    }
}
