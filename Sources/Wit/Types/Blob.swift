import Foundation

public struct Blob: Identifiable, Sendable {
    public let path: String
    public let hash: String?
    public let previousHash: String?

    public var id: String { path }

    public init(path: String, hash: String? = nil, previousHash: String? = nil) {
        self.path = path
        self.hash = hash
        self.previousHash = previousHash
    }

    public func apply(previousHash: String) -> Blob {
        .init(
            path: self.path,
            hash: self.hash,
            previousHash: previousHash,
        )
    }

    public func apply(hash: String) -> Blob {
        .init(
            path: self.path,
            hash: hash,
            previousHash: self.previousHash,
        )
    }
}
