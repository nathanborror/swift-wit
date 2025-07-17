import Foundation

public struct Blob: Storable {
    public var kind = Envelope.Kind.blob
    public var path: String?
    public var content: Data

    public init(data: Data) throws {
        self.path = nil
        self.content = data
    }

    public init(string: String, path: String? = nil) {
        self.path = path
        self.content = string.data(using: .utf8) ?? Data()
    }

    public func encode() throws -> Data {
        content
    }
}
