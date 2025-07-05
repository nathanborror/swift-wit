import Foundation

public struct Tree: Storable {
    public let type = Object.Kind.tree
    public let entries: [Entry]

    public var content: Data {
        let entries = entries.sorted { $0.name < $1.name }
        let content = entries.map { $0.formatted }.joined()
        return content.data(using: .utf8) ?? Data()
    }

    public struct Entry {
        public let mode: Mode
        public let name: String
        public let hash: String

        public var formatted: String {
            "\(mode.rawValue) \(name)\0\(hash)"
        }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }
}

public enum Mode: String {
    case normal = "100644"
    case directory = "040000"
}
