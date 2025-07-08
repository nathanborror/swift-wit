import Foundation

public protocol Storable {
    var type: Object.Kind { get }
    var content: Data { get }
}
