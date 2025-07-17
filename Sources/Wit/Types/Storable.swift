import Foundation

public protocol Storable {
    var kind: Envelope.Kind { get }

    init(data: Data) throws

    func encode() throws -> Data
}

let StorableEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()
