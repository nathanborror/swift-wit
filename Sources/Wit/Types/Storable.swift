import Foundation

public protocol Storable {
    var kind: Envelope.Kind { get }

    init?(data: Data)

    func encode() -> Data
}
