import Foundation

public struct Object {
    public let kind: Kind
    public let content: Data
    public let size: Int

    public enum Kind: String {
        case blob
        case tree
        case commit
    }

    public init?(data: Data) {
        guard let nullIndex = data.firstIndex(of: 0) else {
            return nil
        }

        let headerData = data[..<nullIndex]
        guard let header = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let parts = header.split(separator: " ")
        guard parts.count == 2, let kind = Object.Kind(rawValue: String(parts[0])), let size = Int(parts[1]) else {
            return nil
        }

        let contentStart = data.index(after: nullIndex)
        let content = data[contentStart...]

        self.kind = kind
        self.content = content
        self.size = size
    }
}
