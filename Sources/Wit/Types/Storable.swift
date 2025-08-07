import Foundation

public protocol Storable: Sendable {
    var kind: Envelope.Kind { get }

    init(data: Data) throws

    func encode() throws -> Data
}

