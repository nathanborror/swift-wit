import Foundation

public struct Reference {
    public var path: String
    public var hash: String?
    public var state: State?
    public var mode: Tree.Entry.Mode

    public enum State {
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

    public func apply(kind: State) -> Reference {
        var ref = self
        ref.state = kind
        return ref
    }

    public func apply(hash: String) -> Reference {
        var ref = self
        ref.hash = hash
        return ref
    }
}
