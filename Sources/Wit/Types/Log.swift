import Foundation
import TabularData

/// Log represents what an entry in a log file looks like. The most common log file is the main .wit/logs file which maintains a record of all the Commits. Another
/// common log output is the history for a particular Blob.
///
/// Example .wit/logs file:
///
/// ```
/// Content-Type: text/csv; charset=utf8; header=present; profile=logs
///
/// timestamp,hash,parent,message
/// 1774241205.703834,81de4ffd647d122a7b4a8c44c455d311b9fbd3d8b65ab92e52057a5082457730,,"Initial commit"
/// 1774241234.046763,8b23e036337169e63660fcae3565b15ecf8a978c544e8e363c3921da4c5c9a29,81de4ffd647d122a7b4a8c44c455d311b9fbd3d8b65ab92e52057a5082457730,"Change A"
/// 1774243844.546442,4cc1f7307671df8c0a868552dce5b9f549395ec7c4c6ff0ec648a3594add5742,8b23e036337169e63660fcae3565b15ecf8a978c544e8e363c3921da4c5c9a29,"Change B"
/// 1774243951.2827559,25695cbbedfe5d2ee043ee6136da06821d2d7459049b654324865d004fc533f2,4cc1f7307671df8c0a868552dce5b9f549395ec7c4c6ff0ec648a3594add5742,"Change C"
/// ```

public enum Log: Sendable {
    case commit(Commit)
    case blobChange(BlobChange)

    public struct Commit: Identifiable, Sendable {
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

    public struct BlobChange: Identifiable, Sendable {
        public let timestamp: Date
        public let hash: String
        public let commit: String
        public let message: String?

        public var id: String { timestamp.toRFC1123 }

        public init(timestamp: Date = .now, hash: String, commit: String, message: String?) {
            self.timestamp = timestamp
            self.hash = hash
            self.commit = commit
            self.message = message
        }
    }
}

struct LogEncoder {

    func encode(commit: Commit, hash: String) -> String {
        "\(commit.timestamp.timeIntervalSince1970),\(hash),\(commit.parent ?? ""),\"\(commit.message)\""
    }

    func encode(log: Log) -> String {
        switch log {
        case .commit(let entry):
            return [
                String(entry.timestamp.timeIntervalSince1970),
                entry.hash,
                entry.parent ?? "",
                entry.message
            ]
            .compactMap { $0 }
            .joined(separator: ",")
        case .blobChange(let entry):
            return [
                String(entry.timestamp.timeIntervalSince1970),
                entry.hash,
                entry.commit,
                entry.message
            ]
            .compactMap { $0 }
            .joined(separator: ",")
        }
    }
}

struct LogDecoder {

    func decode(_ csv: String) throws -> [Log] {
        let options = CSVReadingOptions(hasHeaderRow: true, delimiter: ",")
        let frame = try DataFrame(csvData: csv.data(using: .utf8)!, options: options)

        return frame.rows.compactMap { row in
            guard
                let timestampInterval = row["timestamp", TimeInterval.self],
                let hash = row["hash", String.self]
            else { return nil }

            // Commit log entry
            if frame.containsColumn("parent", String.self) {
                let message = row["message", String.self]
                let parent = row["parent", String.self]
                return .commit(.init(timestamp: Date(timeIntervalSince1970: timestampInterval), hash: hash, parent: parent, message: message))
            }

            // Blob change log entry
            if frame.containsColumn("commit", String.self) {
                let message = row["message", String.self]
                let commit = row["commit", String.self]
                return .blobChange(.init(timestamp: Date(timeIntervalSince1970: timestampInterval), hash: hash, commit: commit ?? "", message: message))
            }

            // Unknown log entry
            return nil
        }
    }
}
