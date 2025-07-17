import Foundation

public struct Tree: Storable, Codable {
    public var kind = Envelope.Kind.tree
    public var entries: [Entry]

    public struct Entry: Codable {
        public var mode: Mode
        public var name: String
        public var hash: String

        public enum Mode: String, Codable {
            case normal = "100644"
            case directory = "040000"
            case executable = "100755"
            case symbolicLink = "120000"
        }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(data: Data) throws {
        let tree = try JSONDecoder().decode(Tree.self, from: data)
        self.kind = tree.kind
        self.entries = tree.entries
    }

    public func encode() throws -> Data {
        var tree = self
        tree.entries.sort { $0.name < $1.name }
        return try StorableEncoder.encode(tree)
    }
}
