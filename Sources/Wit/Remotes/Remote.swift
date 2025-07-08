import Foundation
import CryptoKit

public typealias ETag = String

public protocol Remote {
    var baseURL: URL { get }

    func head(url: URL) async throws -> ETag
    func get(url: URL, etag: String?) async throws -> (Data, ETag)
    func put(url: URL, data: Data, mimetype: String?, etag: String?, privateKey: Curve25519.Signing.PrivateKey) async throws -> ETag?
    func delete(url: URL, etag: String?, privateKey: Curve25519.Signing.PrivateKey) async throws
}

public enum RemoteError: Swift.Error, CustomStringConvertible {
    case missingURL
    case missingURLMethod
    case missingURLPath
    case badServerResponse
    case badServerURL
    case preconditionFailed
    case notModified
    case requestFailed(Int, String?)
    case invalidPrivateKey

    public var description: String {
        switch self {
        case .missingURL:
            "Missing URL"
        case .missingURLMethod:
            "Missing URL method"
        case .missingURLPath:
            "Missing URL path"
        case .badServerResponse:
            "The server returned an invalid response."
        case .badServerURL:
            "The provided URL is invalid."
        case .preconditionFailed:
            "The file on the server is different than the file trying to be uploaded."
        case .notModified:
            "The file on the server is the same as the cached file."
        case .requestFailed(let statusCode, let description):
            "Request failed with status code \(statusCode): \(description ?? "no description")"
        case .invalidPrivateKey:
            "Invalid private key"
        }
    }
}
