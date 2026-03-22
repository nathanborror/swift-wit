import Foundation
import MIME
import TabularData

public struct Commit: Sendable {
    public let tree: String
    public let parent: String?
    public let message: String
    public let timestamp: Date

    public init(tree: String, parent: String? = nil, message: String, timestamp: Date = .now) {
        self.tree = tree
        self.parent = parent
        self.message = message
        self.timestamp = timestamp
    }

    public init(data: Data) throws {
        let mime = try MIMEDecoder().decode(data)
        let date = mime.headers[.Date] ?? ""
        self.timestamp = Date.fromRFC1123(date) ?? .now

        let options = CSVReadingOptions(hasHeaderRow: true, delimiter: ",")
        let frame = try DataFrame(csvData: mime.body.data(using: .utf8)!, options: options)

        guard let row = frame.rows.first else {
            throw RepoSession.Error.unknown("malformed commit CSV")
        }
        self.tree = row["tree"]! as? String ?? ""
        self.parent = row["parent"] as? String
        self.message = row["message"]! as? String ?? ""
    }

    public func encode() throws -> Data {
        var mime = MIMEMessage(headers: [
            .Date: timestamp.toRFC1123,
            .ContentType: "text/csv; charset=utf8; header=present; profile=commit"
        ])
        mime.body = """
            tree,parent,message
            \(tree),\(parent ?? ""),\"\(message)\"
            """
        return MIMEEncoder().encode(mime)
    }
}

