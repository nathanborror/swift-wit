import Foundation

public struct FileRef {
    public var path: String
    public var hash: String?
    public var kind: Kind?
    public var mode: Mode

    public enum Kind {
        case added
        case modified
        case deleted
    }

    public init(path: String, hash: String? = nil, kind: Kind? = nil, mode: Mode) {
        self.path = path
        self.hash = hash
        self.kind = kind
        self.mode = mode
    }

    public func apply(kind: Kind) -> FileRef {
        var ref = self
        ref.kind = kind
        return ref
    }

    public func apply(hash: String) -> FileRef {
        var ref = self
        ref.hash = hash
        return ref
    }
}
