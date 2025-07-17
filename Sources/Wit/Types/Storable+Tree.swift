import Foundation

public struct Tree: Storable {
    public var kind = Envelope.Kind.tree
    public var entries: [Entry]

    public struct Entry {
        public var mode: Mode
        public var name: String
        public var hash: String

        public enum Mode: String {
            case normal = "100644"
            case directory = "040000"
            case executable = "100755"
            case symbolicLink = "120000"
        }

        public var encoding: String {
            let parts = [hash, mode.rawValue, ":\(name)"].compactMap { $0 }
            return parts.joined(separator: " ")
        }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(data: Data) throws {
        let content = String(data: data, encoding: .utf8) ?? ""
        var entries: [Tree.Entry] = []

        let lines = content.split(separator: "\n")
        for line in lines {
            guard let range = line.range(of: " :") else { continue }

            let metaSlice = line[..<range.lowerBound]
            let nameSlice = line[range.upperBound...]
            let parts = metaSlice.split(separator: " ").map(String.init)
            let name = nameSlice.trimmingCharacters(in: .whitespacesAndNewlines)

            guard parts.count >= 2 else { continue }

            entries.append(.init(
                mode: .init(rawValue: parts[1]) ?? .normal,
                name: name,
                hash: parts[0]
            ))
        }
        
        self.entries = entries
    }

    public func encode() throws -> Data {
        let entries = entries.sorted { $0.name < $1.name }
        let content = entries.map { $0.encoding }.joined(separator: "\n")
        return content.data(using: .utf8) ?? Data()
    }
}
