import Foundation

public struct Log: Identifiable, Sendable {
    public let timestamp: Date
    public let kind: Kind
    public let parts: [String]
    public let message: String?

    public var id: String { timestamp.toISO8601_UTC }

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
        let timestamp = commit.timestamp.toISO8601_UTC
        let parts = [
            timestamp,
            "COMMIT",
            hash,
            commit.parent,
            ":\(commit.message)",
        ].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    func encode(log: Log) -> String {
        var parts = [
            log.timestamp.toISO8601_UTC,
            log.kind.rawValue,
        ]
        parts += log.parts
        if let message = log.message {
            parts.append(":\(message)")
        }
        return parts
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

struct LogDecoder {

    func decode(_ line: String) -> Log {
        let kind: Log.Kind
        let parts: [String]
        let timestamp: Date
        let message: String?

        if let range = line.range(of: " :") {
            let metaSlice = line[..<range.lowerBound]
            let messageSlice = line[range.upperBound...]
            parts = metaSlice.split(separator: " ").map(String.init)
            message = messageSlice.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            parts = line.split(separator: " ").map(String.init)
            message = nil
        }
        if parts.count >= 2 {
            timestamp = .parseISO8601_UTC(parts[0]) ?? .now
            kind = .init(rawValue: parts[1]) ?? .unknown
            return .init(
                timestamp: timestamp,
                kind: kind,
                parts: Array(parts.dropFirst(2)),
                message: message
            )
        } else {
            return .init(
                timestamp: .now,
                kind: .unknown,
                parts: parts,
                message: message
            )
        }
    }
}
