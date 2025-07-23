import Foundation

public struct File: Identifiable, Sendable {
    public var path: String
    public var hash: String?
    public var state: State?
    public var mode: Tree.Entry.Mode

    public var id: String { path }

    public enum State: Sendable {
        case added
        case modified
        case deleted
    }

    public init(path: String, hash: String? = nil, kind: State? = nil, mode: Tree.Entry.Mode) {
        self.path = path
        self.hash = hash
        self.state = kind
        self.mode = mode
    }

    public func apply(kind: State) -> File {
        var file = self
        file.state = kind
        return file
    }

    public func apply(hash: String) -> File {
        var file = self
        file.hash = hash
        return file
    }
}
