import Foundation

public struct Commit: Storable, Codable, Sendable {
    public let kind: Envelope.Kind
    public let tree: String
    public let parent: String?
    public let message: String
    public let timestamp: Date

    public init(tree: String, parent: String? = nil, message: String, timestamp: Date = .now) {
        self.kind = .commit
        self.tree = tree
        self.parent = parent
        self.message = message
        self.timestamp = timestamp
    }

    public init(data: Data) throws {
        self.kind = .commit

        var tree: String?
        var parent: String?
        var timestamp: Date?
        var message: [String] = []

        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        for line in lines {
            if line.hasPrefix("TREE ") {
                tree = String(line.dropFirst("TREE ".count))
            } else if line.hasPrefix("PARENT ") {
                parent = String(line.dropFirst("PARENT ".count))
            } else if line.hasPrefix("TIMESTAMP ") {
                let str = String(line.dropFirst("TIMESTAMP ".count))
                timestamp = try? Date(str, strategy: .iso8601)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            } else {
                message.append(String(line))
            }
        }

        self.tree = tree ?? ""
        self.parent = parent
        self.timestamp = timestamp ?? .now
        self.message = message.joined(separator: "\n")
    }

    public func encode() throws -> Data {
        var out: [String] = []
        out.append("TREE \(tree)")
        if let parent = parent {
            out.append("PARENT \(parent)")
        }
        out.append("TIMESTAMP \(timestamp.ISO8601Format(.iso8601WithTimeZone(includingFractionalSeconds: true)))")
        out.append("")
        out.append(message)
        return out.joined(separator: "\n").data(using: .utf8)!
    }
}

