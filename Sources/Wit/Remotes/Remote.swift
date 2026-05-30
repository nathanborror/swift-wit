import Foundation

public protocol Remote: Actor {
    var baseURL: URL { get }

    func get(path: String) async throws -> Data
    func put(path: String, data: Data?, directoryHint: URL.DirectoryHint, privateKey: Data?) async throws
    func post(path: String, data: Data?, directoryHint: URL.DirectoryHint, privateKey: Data?) async throws
    func delete(path: String, privateKey: Data?) async throws

    func exists(path: String) async throws -> Bool
    func list(path: String, depth: Int?) async throws -> [String]
    func move(path: String, to toPath: String) async throws

    func sign(request: URLRequest, data: Data?, privateKey: Data) throws -> URLRequest
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
