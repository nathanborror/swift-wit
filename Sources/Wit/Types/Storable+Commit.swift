import Foundation

public struct Commit: Storable, Codable {
    public var kind = Envelope.Kind.commit
    public var tree: String
    public var parent: String?
    public var message: String
    public var timestamp: Date

    public init(tree: String, parent: String? = nil, message: String, timestamp: Date = .now) {
        self.tree = tree
        self.parent = parent
        self.message = message
        self.timestamp = timestamp
    }

    public init(data: Data) throws {
        let commit = try JSONDecoder().decode(Commit.self, from: data)
        self.kind = commit.kind
        self.tree = commit.tree
        self.parent = commit.parent
        self.message = commit.message
        self.timestamp = commit.timestamp
    }

    public func encode() throws -> Data {
        try StorableEncoder.encode(self)
    }
}
