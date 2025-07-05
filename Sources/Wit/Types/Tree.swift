import Foundation

public struct Tree: Storable {
    public let type = Object.Kind.tree
    public let entries: [Entry]

    public var content: Data {
        let entries = entries.sorted { $0.name < $1.name }
        let content = entries.map { $0.formatted }.joined()
        return content.data(using: .utf8) ?? Data()
    }

    public struct Entry {
        public let mode: String
        public let name: String
        public let hash: String

        public var formatted: String {
            "\(mode) \(name)\0\(hash)"
        }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }
}
