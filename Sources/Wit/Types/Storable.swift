import Foundation

public protocol Storable {
    var type: Object.Kind { get }

    init?(data: Data)

    func encode() -> Data
}

extension Storable {

    func applyHeader(_ data: Data) -> Data {
        let header = "\(type.rawValue) \(data.count)\0"
        let headerData = header.data(using: .utf8)!
        return headerData + data
    }
}
