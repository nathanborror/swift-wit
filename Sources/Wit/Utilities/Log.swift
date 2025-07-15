import Foundation

public struct Log {
    public var timestamp: Date? = nil
    public var kind: Kind = .unknown
    public var parts: [String] = []
    public var message: String? = nil

    public enum Kind: String {
        case commit = "COMMIT"
        case unknown = ""
    }
}

struct LogEncoder {

    func encode(commit: Commit, hash: String) -> String {
        let timestamp = dateFormatter(commit.timestamp)
        let parts = [
            timestamp,
            "COMMIT",
            hash,
            commit.parent.isEmpty ? nil : commit.parent,
            ":\(commit.message)",
        ].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    func dateFormatter(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

struct LogDecoder {

    func decode(_ line: String) -> Log {
        var log = Log()
        if let range = line.range(of: " :") {
            let metaSlice = line[..<range.lowerBound]
            let messageSlice = line[range.upperBound...]
            log.parts = metaSlice.split(separator: " ").map(String.init)
            log.message = messageSlice.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            log.parts = line.split(separator: " ").map(String.init)
        }
        if log.parts.count >= 2 {
            log.timestamp = parseISO8601Date(log.parts[0])
            log.kind = .init(rawValue: log.parts[1]) ?? .unknown
        }
        return log
    }

    func parseISO8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }
}
