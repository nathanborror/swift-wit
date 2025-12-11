import Foundation
import MIME

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
        let content = try MIMEDecoder().decode(data)
        let entries = content.headers.values(for: "Wild-Tree")

        self.entries = entries.map {
            let attrs = MIMEHeaderAttributes.parse($0)
            let mode = Entry.Mode(rawValue: attrs["mode"] ?? "") ?? .normal
            let name = attrs["name"] ?? ""
            return .init(mode: mode, name: name, hash: attrs.value)
        }
    }

    public func encode() throws -> Data {
        var contents = ["Content-Type: text/x-wild-tree"]
        contents += entries.map {
            "Wild-Tree: \($0.hash); name=\"\($0.name)\"; mode=\($0.mode.rawValue)"
        }
        guard let data = contents.joined(separator: "\n").data(using: .utf8) else {
            throw Repo.Error.unknown("Failed to encode commit")
        }
        return data
    }
}
