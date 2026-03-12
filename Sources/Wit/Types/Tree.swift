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

        public enum Mode: String, Codable, Sendable {
            case normal
            case directory
        }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(data: Data) throws {
        let mime = try MIMEDecoder().decode(data)
        let options = CSVReadingOptions(hasHeaderRow: true, delimiter: ",")
        let frame = try DataFrame(csvData: mime.body.data(using: .utf8)!, options: options)

        self.entries = frame.rows.map {
            let hash = $0["hash"] as? String ?? ""
            let name = $0["name"] as? String ?? ""
            let modeStr = $0["mode"] as? String ?? ""
            let mode = Entry.Mode(rawValue: modeStr) ?? .normal
            return .init(mode: mode, name: name, hash: hash)
        }
    }

    public func encode() throws -> Data {
        var mime = MIMEMessage(headers: [.ContentType: "text/csv; charset=utf8; header=present; profile=tree"])
        mime.body = """
            hash,mode,name
            
            \(entries.map { "\($0.hash),\($0.mode.rawValue),\"\($0.name)\"" }.joined(separator: "\n"))
            """
        return MIMEEncoder().encode(mime)
    }
}
