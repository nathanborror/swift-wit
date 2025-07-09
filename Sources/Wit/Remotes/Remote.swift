import Foundation
import CryptoKit

public typealias PrivateKey = Curve25519.Signing.PrivateKey

public protocol Remote {
    func register(userID: String, privateKey: PrivateKey) async throws
    func register() async throws -> (String, PrivateKey)
    func unregister() async throws

    func get(path: String) async throws -> Data
    func put(path: String, data: Data, mimetype: String?) async throws
    func delete(path: String) async throws
}

public enum RemoteError: Swift.Error, CustomStringConvertible {
    case missingURL
    case missingURLMethod
    case missingURLPath
    case missingPrivateKey
    case missingUserID
    case badServerResponse
    case badServerURL
    case requestFailed(Int, String?)

    public var description: String {
        switch self {
        case .missingURL:
            "Missing URL"
        case .missingURLMethod:
            "Missing URL method"
        case .missingURLPath:
            "Missing URL path"
        case .missingPrivateKey:
            "Missing private key"
        case .missingUserID:
            "Missing user id"
        case .badServerResponse:
            "The server returned an invalid response."
        case .badServerURL:
            "The provided URL is invalid."
        case .requestFailed(let statusCode, let description):
            "Request failed with status code \(statusCode): \(description ?? "no description")"
        }
    }
}
