import Foundation

public struct Blob: Storable {
    public let type = Object.Kind.blob
    public let content: Data

    public init?(data: Data) {
        self.content = data
    }

    public init(string: String) {
        self.content = string.data(using: .utf8) ?? Data()
    }

    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        self.content = data
    }

    public func encode() -> Data {
        return applyHeader(content)
    }
}
