import Foundation
import CryptoKit

public protocol Remote {
    typealias PrivateKey = Curve25519.Signing.PrivateKey

    func exists(path: String) async throws -> Bool
    func get(path: String) async throws -> Data
    func put(path: String, data: Data, mimetype: String?, privateKey: PrivateKey?) async throws
    func delete(path: String, privateKey: PrivateKey?) async throws
    func list(path: String, ignores: [String]) async throws -> [String: URL]
}

public enum RemoteError: Swift.Error, CustomStringConvertible {
    case missingURL
    case missingURLMethod
    case missingURLPath
    case missingPrivateKey
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
        case .badServerResponse:
            "The server returned an invalid response."
        case .badServerURL:
            "The provided URL is invalid."
        case .requestFailed(let statusCode, let description):
            "Request failed with status code \(statusCode): \(description ?? "no description")"
        }
    }
}
