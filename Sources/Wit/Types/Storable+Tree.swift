import Foundation

public struct Tree: Storable, Codable, Sendable {
    public let kind: Envelope.Kind
    public let entries: [Entry]

    public struct Entry: Codable, Identifiable, Sendable {
        public let mode: Mode
        public let name: String
        public let hash: String

        public var id: String { hash+name }

        public enum Mode: String, Codable, Sendable {
            case normal = "100644"
            case directory = "040000"
            case executable = "100755"
            case symbolicLink = "120000"
        }
    }

    public init(entries: [Entry]) {
        self.kind = .tree
        self.entries = entries
    }

    public init(data: Data) throws {
        let tree = try JSONDecoder().decode(Tree.self, from: data)
        self.kind = tree.kind
        self.entries = tree.entries
    }

    public func encode() throws -> Data {
        let entries = self.entries.sorted { $0.name < $1.name }
        let tree = Tree(entries: entries)
        return try StorableEncoder.encode(tree)
    }
}
