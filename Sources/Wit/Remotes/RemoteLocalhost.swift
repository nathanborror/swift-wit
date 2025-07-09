import Foundation
import OSLog
import CryptoKit

private let logger = Logger(subsystem: "Remote", category: "Wit")

public actor RemoteLocalhost: Remote {
    private let baseURL: URL
    private let session: URLSession
    private let maxConcurrentUploads = 5
    private var userID: String? = nil
    private var privateKey: PrivateKey? = nil

    public init(baseURL: URL) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = maxConcurrentUploads
        configuration.timeoutIntervalForRequest = 300 // 5 minutes
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData // ensures manual ETag checking works
        self.session = URLSession(configuration: configuration)
    }

    public func register(userID: String, privateKey: PrivateKey) async throws {
        self.userID = userID
        self.privateKey = privateKey
    }

    public func register() async throws -> (String, PrivateKey) {
        userID = UUID().uuidString
        privateKey = Curve25519.Signing.PrivateKey()

        guard let userID else {
            throw RemoteError.missingUserID
        }
        guard let privateKey else {
            throw RemoteError.missingPrivateKey
        }

        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let url = baseURL.appending(path: "register")
        let data = """
            {"id": "\(userID)", "publicKey": "\(publicKey)"}
            """.data(using: .utf8)!
        let _ = try await put(url: url, data: data, mimetype: "application/json")
        return (userID, privateKey)
    }

    public func unregister() async throws {
        guard let userID else {
            throw RemoteError.missingUserID
        }
        let unregisterURL = URL(string: "http://localhost:8080/\(userID)/unregister")!
        let _ = try await put(url: unregisterURL, data: Data(), mimetype: nil)
    }

    public func get(path: String) async throws -> Data {
        guard let userID else { throw RemoteError.missingUserID }
        let url = baseURL.appending(path: userID).appending(path: path)
        return try await get(url: url)
    }

    public func put(path: String, data: Data, mimetype: String?) async throws {
        guard let userID else { throw RemoteError.missingUserID }
        let url = baseURL.appending(path: userID).appending(path: path)
        return try await put(url: url, data: data, mimetype: mimetype)
    }

    public func delete(path: String) async throws {
        guard let userID else { throw RemoteError.missingUserID }
        let url = baseURL.appending(path: userID).appending(path: path)
        try await delete(url: url)
    }

    // MARK: Private

    private func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }
        switch httpResponse.statusCode {
        case 200:
            logger.info("GET (\(url.path))")
            return data
        default:
            logger.error("GET Error (\(url.path), \(httpResponse.statusCode)): \(String(data: data, encoding: .utf8)!)")
            throw RemoteError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }
    }

    private func put(url: URL, data: Data, mimetype: String?) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        if let mimetype {
            request.setValue(mimetype, forHTTPHeaderField: "Content-Type")
        }
        if let privateKey {
            request = try sign(request: request, privateKey: privateKey)
        }

        let (data, resp) = try await session.upload(for: request, from: data)
        guard let httpResponse = resp as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }
        switch httpResponse.statusCode {
        case 200:
            logger.info("PUT (\(request.url?.path ?? "."))")
            return
        default:
            logger.error("PUT Error: (\(request.url?.path ?? "."), \(httpResponse.statusCode)) — \(request.url!.path) `\(String(data: data, encoding: .utf8) ?? "Unknown")`")
            throw RemoteError.requestFailed(httpResponse.statusCode, request.url?.absoluteString)
        }
    }

    private func delete(url: URL) async throws {
        guard let privateKey else {
            throw RemoteError.missingPrivateKey
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request = try sign(request: request, privateKey: privateKey)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            logger.info("DELETE (\(url.path))")
            return
        default:
            let message = String(data: data, encoding: .utf8) ?? "Unknown"
            logger.error("DELETE Error (\(url.path), \(httpResponse.statusCode)): \(message)")
            throw RemoteError.requestFailed(httpResponse.statusCode, message)
        }
    }

    private func sign(request: URLRequest, privateKey: Curve25519.Signing.PrivateKey) throws -> URLRequest {
        var request = request
        guard let method = request.httpMethod else {
            throw RemoteError.missingURLMethod
        }
        guard let path = request.url?.path else {
            throw RemoteError.missingURLPath
        }
        let timestamp = String(Int(Date().timeIntervalSince1970))

        let message = "\(method)\n\(path)\n\(timestamp)"
        let messageData = message.data(using: .utf8)!
        let signature = try! privateKey.signature(for: messageData)

        let signatureBase64 = Data(signature).base64EncodedString()

        request.setValue(signatureBase64, forHTTPHeaderField: "X-Wild-Signature")
        request.setValue(timestamp, forHTTPHeaderField: "X-Wild-Timestamp")
        return request
    }
}
