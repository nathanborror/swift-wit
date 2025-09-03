import Foundation

public struct Tree: Sendable {
    public let entries: [Entry]

    public struct Entry: Codable, Identifiable, Sendable {
        public let mode: Mode
        public let name: String
        public let hash: String

        public var id: String { hash+name }

        public enum Mode: String, Codable, Sendable {
            case normal = "100644"
            case directory = "040000"
            case executable = "100755"
            case symbolicLink = "120000"
        }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(data: Data) throws {
        let lines = String(data: data, encoding: .utf8)!
            .split(separator: "\n")
            .filter { !$0.isEmpty }

        self.entries = lines.compactMap { line in
            guard let colonIndex = line.firstIndex(of: ":") else { return nil }
            let prefix = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            let name = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            let parts = prefix.split(separator: " ")
            guard parts.count >= 3 else { return nil }
            guard let mode = Entry.Mode(rawValue: String(parts[0])) else { return nil }
            return .init(mode: mode, name: name, hash: String(parts[2]))
        }
    }

    public func encode() throws -> Data {
        entries
            .sorted { $0.name < $1.name }
            .map { "\($0.mode.rawValue) \($0.mode == .directory ? "TREE" : "BLOB") \($0.hash) :\($0.name)" }
            .joined(separator: "\n")
            .data(using: .utf8)!
    }
}
