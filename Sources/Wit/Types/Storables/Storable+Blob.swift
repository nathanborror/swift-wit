import Foundation

public struct Blob: Storable {
    public var kind = Envelope.Kind.blob
    public var content: Data

    public init?(data: Data) {
        self.content = data
    }

    public init(string: String) {
        self.content = string.data(using: .utf8) ?? Data()
    }

    public func encode() -> Data {
        content
    }
}
