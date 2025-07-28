import Foundation

public struct Commit: Storable, Codable, Sendable {
    public let kind: Envelope.Kind
    public let tree: String
    public let parent: String?
    public let message: String
    public let timestamp: Date

    public init(tree: String, parent: String? = nil, message: String, timestamp: Date = .now) {
        self.kind = .commit
        self.tree = tree
        self.parent = parent
        self.message = message
        self.timestamp = timestamp
    }

    public init(data: Data) throws {
        let commit = try JSONDecoder().decode(Commit.self, from: data)
        self.kind = .commit
        self.tree = commit.tree
        self.parent = commit.parent
        self.message = commit.message
        self.timestamp = commit.timestamp
    }

    public func encode() throws -> Data {
        try StorableEncoder.encode(self)
    }
}
