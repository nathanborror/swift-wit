import Foundation
import OSLog
import CryptoKit

private let logger = Logger(subsystem: "Remote", category: "Wit")

public actor LocalRemote: Remote {
    public let baseURL: URL

    private let session: URLSession
    private let maxConcurrentUploads = 5

    public init(baseURL: URL) {
        self.baseURL = baseURL
        
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = maxConcurrentUploads
        configuration.timeoutIntervalForRequest = 300 // 5 minutes
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData // ensures manual ETag checking works
        self.session = URLSession(configuration: configuration)
    }

    public func head(url: URL) async throws -> ETag {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }
        switch httpResponse.statusCode {
        case 200:
            guard let etag = httpResponse.value(forHTTPHeaderField: "ETag") else {
                throw RemoteError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8))
            }
            logger.info("HEAD (\(url.path), ETag: \(etag))")
            return etag
        default:
            logger.error("HEAD Error (\(url.path), \(httpResponse.statusCode)): \(String(data: data, encoding: .utf8)!)")
            throw RemoteError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }
    }

    public func get(url: URL, etag: String?) async throws -> (Data, ETag) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }
        switch httpResponse.statusCode {
        case 200:
            guard let etag = httpResponse.value(forHTTPHeaderField: "ETag") else {
                throw RemoteError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8))
            }
            logger.info("GET (\(url.path), ETag: \(etag))")
            return (data, etag)
        case 304:
            logger.info("GET Skipped (\(url.path), ETag matches cache)")
            throw RemoteError.notModified
        default:
            logger.error("GET Error (\(url.path), \(httpResponse.statusCode)): \(String(data: data, encoding: .utf8)!)")
            throw RemoteError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }
    }

    public func put(url: URL, data: Data, mimetype: String? = nil, etag: String?, privateKey: Curve25519.Signing.PrivateKey) async throws -> ETag? {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        if let mimetype {
            request.setValue(mimetype, forHTTPHeaderField: "Content-Type")
        }
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        request = try sign(request: request, privateKey: privateKey)

        let (data, resp) = try await session.upload(for: request, from: data)
        guard let httpResponse = resp as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }
        switch httpResponse.statusCode {
        case 200:
            if let etag = httpResponse.value(forHTTPHeaderField: "ETag") {
                logger.info("PUT (\(request.url?.path ?? "."), ETag: \(etag))")
                return etag
            }
            logger.info("PUT (\(request.url?.path ?? "."), ETag: nil)")
            return nil
        case 412:
            logger.info("PUT Skipped (\(request.url?.path ?? "."), ETag doesn't match server)")
            throw RemoteError.preconditionFailed
        default:
            logger.error("PUT Error: (\(request.url?.path ?? "."), \(httpResponse.statusCode)) — \(request.url!.path) `\(String(data: data, encoding: .utf8) ?? "Unknown")`")
            throw RemoteError.requestFailed(httpResponse.statusCode, request.url?.absoluteString)
        }
    }

    public func delete(url: URL, etag: String?, privateKey: Curve25519.Signing.PrivateKey) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        // Check Etag to make sure the server data hasn't changed.
        // Amazon S3 doesn't support If-Match on DELETE requests so need to perform a HEAD request.
        if let serverEtag = try? await head(url: url), serverEtag != etag {
            throw RemoteError.preconditionFailed
        }

        request = try sign(request: request, privateKey: privateKey)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            logger.info("DELETE (\(url.path))")
            return
        case 412:
            logger.info("DELETE Skipped (\(url.path), ETag doesn't match server)")
            throw RemoteError.preconditionFailed
        default:
            let message = String(data: data, encoding: .utf8) ?? "Unknown"
            logger.error("DELETE Error (\(url.path), \(httpResponse.statusCode)): \(message)")
            throw RemoteError.requestFailed(httpResponse.statusCode, message)
        }
    }

    // MARK: Private

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
