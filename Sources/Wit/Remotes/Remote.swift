import Foundation
import CryptoKit

public protocol Remote: Actor {
    typealias PrivateKey = Curve25519.Signing.PrivateKey

    var baseURL: URL { get }

    func exists(path: String) async throws -> Bool
    func get(path: String) async throws -> Data
    func put(path: String, data: Data?, directoryHint: URL.DirectoryHint, privateKey: PrivateKey?) async throws
    func post(path: String, data: Data?, directoryHint: URL.DirectoryHint, privateKey: PrivateKey?) async throws
    func delete(path: String, privateKey: PrivateKey?) async throws
    func move(path: String, to toPath: String) async throws
    func list(path: String, depth: Int?) async throws -> [String]
}

extension Remote {
    public func list(path: String) async throws -> [String] {
        try await list(path: path, depth: nil)
    }
}

public enum RemoteError: Swift.Error, CustomStringConvertible {
    case missingURL
    case missingURLMethod
    case missingURLPath
    case missingPrivateKey
    case unauthorized
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
        case .unauthorized:
            "The request was unauthorized."
        case .badServerResponse:
            "The server returned an invalid response."
        case .badServerURL:
            "The provided URL is invalid."
        case .requestFailed(let statusCode, let description):
            "Request failed with status code \(statusCode): \(description ?? "no description")"
        }
    }
}
