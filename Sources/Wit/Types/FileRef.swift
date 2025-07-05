import Foundation

public struct FileRef {
    public let path: String
    public let hash: String?
    public var kind: Kind?
    public let mode: String

    public enum Kind {
        case added
        case modified
        case deleted
    }

    public init(path: String, hash: String? = nil, kind: Kind? = nil, mode: String) {
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
}
