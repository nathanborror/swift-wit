import Foundation

public struct Blob: Storable, Sendable {
    public var kind = Envelope.Kind.blob
    public var content: Data

    public init(data: Data) throws {
        self.content = data
    }

    public init(string: String) {
        self.content = string.data(using: .utf8) ?? Data()
    }

    public func encode() throws -> Data {
        content
    }
}
