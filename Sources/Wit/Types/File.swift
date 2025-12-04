import Foundation

public struct File: Identifiable, Sendable {
    public let path: FilePath
    public let hash: String?
    public let previousHash: String?
    public let state: State?
    public let mode: Tree.Entry.Mode

    public var id: String { path }

    public enum State: Sendable {
        case added
        case modified
        case deleted
    }

    public init(path: FilePath, hash: String? = nil, previousHash: String? = nil, state: State? = nil, mode: Tree.Entry.Mode) {
        self.path = path
        self.hash = hash
        self.previousHash = previousHash
        self.state = state
        self.mode = mode
    }

    public func apply(state: State? = nil, previousHash: String?) -> File {
        .init(
            path: self.path,
            hash: self.hash,
            previousHash: previousHash,
            state: state,
            mode: self.mode
        )
    }

    public func apply(hash: String) -> File {
        .init(
            path: self.path,
            hash: hash,
            previousHash: self.previousHash,
            state: self.state,
            mode: self.mode
        )
    }
}

public typealias FilePath = String

extension FilePath {

    public func deletingLastPath() -> FilePath {
        let url = URL(fileURLWithPath: self)
        let dir = url.deletingLastPathComponent()
        let path = dir.relativePath.trimmingPrefix(".")
        return .init(path)
    }

    public func lastPathComponent() -> String {
        let url = URL(fileURLWithPath: self)
        return url.lastPathComponent
    }
}
