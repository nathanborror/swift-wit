import Foundation

public struct Log: Identifiable, Sendable {
    public let timestamp: Date
    public let kind: Kind
    public let parts: [String]
    public let message: String?

    public var id: String { timestamp.toRFC1123 }

    public enum Kind: String, Sendable {
        case commit = "COMMIT"
        case unknown = ""
    }

    public init(timestamp: Date = .now, kind: Kind = .unknown, parts: [String], message: String?) {
        self.timestamp = timestamp
        self.kind = kind
        self.parts = parts
        self.message = message
    }
}

struct LogEncoder {

    func encode(commit: Commit, hash: String) -> String {
        let parts = [
            commit.timestamp.toRFC1123,
            "COMMIT",
            hash,
            commit.parent ?? "",
            "\"\(commit.message)\""
        ]
        return parts.joined(separator: ",")
    }

    func encode(log: Log) -> String {
        var parts = [
            log.timestamp.toRFC1123,
            log.kind.rawValue,
        ]
        parts += log.parts
        if let message = log.message {
            parts.append(message)
        }
        return parts.joined(separator: ",")
    }
}

struct LogDecoder {

    func decode(_ lines: String) -> [Log] {
        let rows = CSVDecoder().decode(lines)
        return rows.compactMap { row in
            guard row.count >= 5 else { return nil }
            return Log(
                timestamp: Date.fromRFC1123(row[0]) ?? .now,
                kind: .init(rawValue: row[1]) ?? .unknown,
                parts: [row[2], row[3]],
                message: row[4]
            )
        }
    }
}
