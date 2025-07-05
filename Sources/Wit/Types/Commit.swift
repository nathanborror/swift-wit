import Foundation

public struct Commit: Storable {
    public let type = Object.Kind.commit
    public let tree: String
    public let parent: String
    public let author: String
    public let message: String
    public let timestamp: Date

    public var content: Data {
        var lines: [String] = []
        lines.append("tree \(tree)")

        if !parent.isEmpty {
            lines.append("parent: \(parent)")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = Commit.dateFormat
        let dateString = dateFormatter.string(from: timestamp)

        lines.append("author \(author) \(dateString)")
        lines.append("")
        lines.append(message)

        let content = lines.joined(separator: "\n")
        return content.data(using: .utf8) ?? Data()
    }

    public static let dateFormat = "yyyy-MM-dd HH:mm:ss Z"
}
