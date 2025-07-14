import Foundation

public struct Commit: Storable {
    public var kind = Envelope.Kind.commit
    public var tree: String
    public var parent: String
    public var author: String
    public var message: String
    public var timestamp: Date

    public static let dateFormat = "yyyy-MM-dd HH:mm:ss Z"

    public init (tree: String, parent: String = "", author: String = "", message: String, timestamp: Date = .now) {
        self.tree = tree
        self.parent = parent
        self.author = author
        self.message = message
        self.timestamp = timestamp
    }

    public init?(data: Data) {
        guard let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        var tree = ""
        var parent = ""
        var author = ""
        var timestamp = Date()
        var message = ""
        var messageStartIndex = 0

        for (index, line) in lines.enumerated() {
            if line.starts(with: treePrefix) {
                tree = String(line.trimmingPrefix(treePrefix))
            } else if line.starts(with: parentPrefix) {
                parent = String(line.trimmingPrefix(parentPrefix))
            } else if line.starts(with: authorPrefix) {
                let authorLine = String(line.trimmingPrefix(authorPrefix))
                // Parse author and timestamp
                if let lastSpaceIndex = authorLine.lastIndex(of: " ") {
                    let dateStartIndex = authorLine.index(before: lastSpaceIndex)
                    if let secondLastSpaceIndex = authorLine[..<dateStartIndex].lastIndex(of: " ") {
                        author = String(authorLine[..<secondLastSpaceIndex])
                        let dateString = String(authorLine[authorLine.index(after: secondLastSpaceIndex)...])

                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = Commit.dateFormat
                        timestamp = dateFormatter.date(from: dateString) ?? Date()
                    }
                }
            } else if line.isEmpty && messageStartIndex == 0 {
                messageStartIndex = index + 1
                break
            }
        }

        if messageStartIndex < lines.count {
            message = lines[messageStartIndex...].joined(separator: "\n")
        }

        self.tree = tree
        self.parent = (parent != EmptyHash) ? parent : ""
        self.author = author
        self.message = message
        self.timestamp = timestamp
    }

    public func encode() -> Data {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = Commit.dateFormat
        let dateString = dateFormatter.string(from: timestamp)

        var lines: [String] = []
        lines.append("\(treePrefix)\(tree)")
        lines.append("\(parentPrefix)\(parent.isEmpty ? EmptyHash : parent)")
        lines.append("\(authorPrefix)\(author) \(dateString)")
        lines.append("")
        lines.append(message)

        let content = lines.joined(separator: "\n")
        return content.data(using: .utf8) ?? Data()
    }

    private let treePrefix = "tree: "
    private let parentPrefix = "parent: "
    private let authorPrefix = "author: "
}

public let EmptyHash = "0000000000000000000000000000000000000000000000000000000000000000"
