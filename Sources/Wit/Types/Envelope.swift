import Foundation

public struct Envelope {
    public let kind: Kind
    public let content: Data

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
        guard parts.count == 2, let kind = Self.Kind(rawValue: String(parts[0])) else {
            return nil
        }

        let contentStart = data.index(after: nullIndex)
        let content = data[contentStart...]

        self.kind = kind
        self.content = content
    }

    public init(storable: any Storable) throws {
        self.kind = storable.kind
        self.content = try storable.encode()
    }

    public func encode() -> Data {
        let header = "\(kind.rawValue) \(content.count)\0"
        let headerData = header.data(using: .utf8)!
        return headerData + content
    }
}
