import Foundation

public struct Tree: Storable {
    public var kind = Envelope.Kind.tree
    public var entries: [Entry]

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

    public init?(data: Data) {
        let content = String(data: data, encoding: .utf8) ?? ""
        var entries: [Tree.Entry] = []

        var currentIndex = content.startIndex

        while currentIndex < content.endIndex {
            // Parse mode (e.g., "100644")
            guard let spaceIndex = content[currentIndex...].firstIndex(of: " ") else { break }
            let modeRaw = String(content[currentIndex..<spaceIndex])
            guard let mode = Mode(rawValue: modeRaw) else { break }

            // Parse name
            currentIndex = content.index(after: spaceIndex)
            guard let nullIndex = content[currentIndex...].firstIndex(of: "\0") else { break }
            let name = String(content[currentIndex..<nullIndex])

            // Parse hash (32 bytes = 64 hex characters for SHA-256)
            currentIndex = content.index(after: nullIndex)
            let hashEndIndex = content.index(currentIndex, offsetBy: 64, limitedBy: content.endIndex) ?? content.endIndex
            let hash = String(content[currentIndex..<hashEndIndex])

            entries.append(Tree.Entry(mode: mode, name: name, hash: hash))

            currentIndex = hashEndIndex
        }
        self.entries = entries
    }

    public func encode() -> Data {
        let entries = entries.sorted { $0.name < $1.name }
        let content = entries.map { $0.formatted }.joined()
        return content.data(using: .utf8) ?? Data()
    }
}

public enum Mode: String {
    case normal = "100644"
    case directory = "040000"
}
