import Foundation
import TabularData

public struct Log: Identifiable, Sendable {
    public let timestamp: Date
    public let hash: String
    public let parent: String?
    public let message: String?

    public var id: String { timestamp.toRFC1123 }

    public init(timestamp: Date = .now, hash: String, parent: String?, message: String?) {
        self.timestamp = timestamp
        self.hash = hash
        self.parent = parent
        self.message = message
    }
}

struct LogEncoder {

    func encode(commit: Commit, hash: String) -> String {
        "\(commit.timestamp.timeIntervalSince1970),\(hash),\(commit.parent ?? ""),\"\(commit.message)\""
    }

    func encode(log: Log) -> String {
        var out = "\(log.timestamp.timeIntervalSince1970),\(log.hash),\(log.parent ?? ""),"
        if let message = log.message {
            out += "\"\(message)\""
        }
        return out
    }
}

struct LogDecoder {

    func decode(_ csv: String) throws -> [Log] {
        let options = CSVReadingOptions(hasHeaderRow: true, delimiter: ",")
        let frame = try DataFrame(csvData: csv.data(using: .utf8)!, options: options)

        return frame.rows.compactMap { row in
            let timestamp = row["timestamp"] as? Double ?? 0
            return Log(
                timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                hash: row["hash"] as! String,
                parent: row["parent"] as? String,
                message: row["message"] as? String
            )
        }
    }
}
