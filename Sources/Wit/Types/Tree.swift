import Foundation
import MIME
import TabularData

public struct Tree: Sendable {
    public let entries: [Entry]

    public struct Entry: Codable, Identifiable, Sendable {
        public let mode: Mode
        public let name: String
        public let hash: String

        public var id: String { hash+name }

        public enum Mode: Int, Codable, Sendable {
            case normal = 100644
            case directory = 0o40000
        }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(data: Data) throws {
        let message = try MIMEDecoder().decode(data)
        guard let part = message.parts.first else {
            throw Repo.Error.unknown("missing tree part")
        }

        let options = CSVReadingOptions(hasHeaderRow: true, delimiter: ",")
        let frame = try DataFrame(csvData: part.body.data(using: .utf8)!, options: options)

        self.entries = frame.rows.map {
            let hash = $0["hash"] as? String ?? ""
            let name = $0["name"] as? String ?? ""
            let modeInt = $0["mode"] as? Int ?? 0
            let mode = Entry.Mode(rawValue: modeInt) ?? .normal
            return .init(mode: mode, name: name, hash: hash)
        }
    }

    public func encode() throws -> Data {
        var contents = [
            "Content-Type: text/csv; charset=utf8; header=present; profile=tree",
            "",
            "hash,mode,name"
        ]
        contents += entries.map { "\($0.hash),\($0.mode.rawValue),\"\($0.name)\"" }
        guard let data = contents.joined(separator: "\n").data(using: .utf8) else {
            throw Repo.Error.unknown("Failed to encode commit")
        }
        return data
    }
}
