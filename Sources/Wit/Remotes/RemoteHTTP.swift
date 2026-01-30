import Foundation
import OSLog

private let logger = Logger(subsystem: "RemoteHTTP", category: "Wit")

public actor RemoteHTTP: Remote {
    public let baseURL: URL

    let session: URLSession
    let maxConcurrentUploads = 5

    public init(baseURL: URL) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = maxConcurrentUploads
        configuration.timeoutIntervalForRequest = 300 // 5 minutes
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData // ensures manual ETag checking works
        self.session = URLSession(configuration: configuration)
    }

    public func exists(path: String) async throws -> Bool {
        var request = URLRequest(url: baseURL/path)
        request.httpMethod = "HEAD"

        let (body, resp) = try await session.data(for: request)
        guard let httpResponse = resp as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }

        switch httpResponse.statusCode {
        case 200:
            logger.info("HEAD (\(request.url?.path ?? ""))")
            return true
        case 404:
            logger.info("HEAD (\(request.url?.path ?? "")): Not Found")
            return false
        default:
            logger.error("HEAD Error (\(request.url?.path ?? ""), \(httpResponse.statusCode)): \(String(data: body, encoding: .utf8)!)")
            throw RemoteError.requestFailed(httpResponse.statusCode, String(data: body, encoding: .utf8))
        }
    }

    public func get(path: String) async throws -> Data {
        var request = URLRequest(url: baseURL/path)
        request.httpMethod = "GET"

        let (body, resp) = try await session.data(for: request)
        guard let httpResponse = resp as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }

        switch httpResponse.statusCode {
        case 200:
            logger.info("GET (\(request.url?.path ?? ""))")
            return body
        default:
            logger.error("GET Error (\(request.url?.path ?? ""), \(httpResponse.statusCode)): \(String(data: body, encoding: .utf8)!)")
            throw RemoteError.requestFailed(httpResponse.statusCode, String(data: body, encoding: .utf8))
        }
    }

    public func put(path: String, data: Data?, directoryHint: URL.DirectoryHint, privateKey: PrivateKey?) async throws {

        // Server doesn't have a concept of directories (yet)
        guard let data, directoryHint != .isDirectory else { return }

        var request = URLRequest(url: baseURL/path)
        request.httpMethod = "PUT"
        if let privateKey {
            request = try sign(request: request, privateKey: privateKey)
        }

        let (body, resp) = try await session.upload(for: request, from: data)
        guard let httpResponse = resp as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            logger.info("PUT (\(request.url?.path ?? "."))")
            return
        default:
            logger.error("PUT Error: (\(request.url?.path ?? "."), \(httpResponse.statusCode)) — \(request.url!.path) `\(String(data: body, encoding: .utf8) ?? "Unknown")`")
            throw RemoteError.requestFailed(httpResponse.statusCode, request.url?.absoluteString)
        }
    }

    public func delete(path: String, privateKey: PrivateKey?) async throws {
        var request = URLRequest(url: baseURL/path)
        request.httpMethod = "DELETE"
        if let privateKey {
            request = try sign(request: request, privateKey: privateKey)
        }

        let (body, resp) = try await session.data(for: request)
        guard let httpResponse = resp as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            logger.info("DELETE (\(request.url?.path ?? ""))")
            return
        default:
            let message = String(data: body, encoding: .utf8) ?? "Unknown"
            logger.error("DELETE Error (\(request.url?.path ?? ""), \(httpResponse.statusCode)): \(message)")
            throw RemoteError.requestFailed(httpResponse.statusCode, message)
        }
    }

    public func move(path: String, to toPath: String) async throws {
        logger.warning("RemoteHTTP.move not implemented")
    }

    public func list(path: String) async throws -> [String] {
        var url = baseURL/path
        if !path.hasSuffix("/") {
            url = baseURL/"\(path)/"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (body, resp) = try await session.data(for: request)
        guard let httpResponse = resp as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let content = String(data: body, encoding: .utf8) ?? ""
            return content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .map { String($0.trimmingPrefix(baseURL.path())) }
                .map { String($0.trimmingPrefix("/")) }
        default:
            logger.error("GET Error (\(request.url?.path ?? ""), \(httpResponse.statusCode)): \(String(data: body, encoding: .utf8)!)")
            throw RemoteError.requestFailed(httpResponse.statusCode, String(data: body, encoding: .utf8))
        }
    }

    // MARK: - Private

    private func sign(request: URLRequest, privateKey: PrivateKey) throws -> URLRequest {
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
