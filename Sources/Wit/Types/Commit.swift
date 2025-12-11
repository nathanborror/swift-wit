import Foundation
import MIME

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
        let content = try MIMEParser.parse(data)
        
        self.tree = content.headers["Wild-Tree"] ?? ""
        self.parent = content.headers["Wild-Parent"]
        self.message = content.body ?? ""

        let date = content.headers["Date"] ?? ""
        self.timestamp = Date.fromRFC1123(date) ?? .now
    }

    public func encode() throws -> Data {
        var content = """
            Date: \(timestamp.toRFC1123)
            Content-Type: text/x-wild-commit
            Wild-Tree: \(tree)
            
            """
        if let parent {
            content += """
            Wild-Parent: \(parent)
            
            """
        }
        content += """
            
            \(message)
            """
        return content.data(using: .utf8)!
    }
}

