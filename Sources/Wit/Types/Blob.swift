import Foundation

public struct Blob: Storable {
    public let type = Object.Kind.blob
    public let content: Data

    public init(content: Data) {
        self.content = content
    }

    public init(string: String) {
        self.content = string.data(using: .utf8) ?? Data()
    }
}
