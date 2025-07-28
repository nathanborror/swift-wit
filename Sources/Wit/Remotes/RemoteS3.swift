import Foundation
import OSLog
import CommonCrypto

private let logger = Logger(subsystem: "RemoteS3", category: "Wit")

public actor RemoteS3: Remote {

    let bucket: String
    let region: String
    let accessKey: String
    let secretKey: String

    let baseURL: URL
    let session: URLSession
    let maxConcurrentUploads = 5

    public init(bucket: String, path: String, region: String, accessKey: String, secretKey: String) {
        self.bucket = bucket
        self.region = region
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.baseURL = URL(string: "https://s3.\(region).amazonaws.com")!.appending(path: bucket).appending(path: path)

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

        // Amazon doesn't have a concept of directories (yet)
        guard directoryHint != .isDirectory else {
            return
        }
        var request = URLRequest(url: baseURL/path)
        request.httpMethod = "PUT"

        let data = data ?? Data()

        if let privateKey {
            request = try sign(request: request, data: data, privateKey: privateKey)
        }

        let (body, resp) = try await session.upload(for: request, from: data)
        guard let httpResponse = resp as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }

        switch httpResponse.statusCode {
        case 200:
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
            request = try sign(request: request, data: Data(), privateKey: privateKey)
        }

        let (body, resp) = try await session.data(for: request)
        guard let httpResponse = resp as? HTTPURLResponse else {
            throw RemoteError.badServerResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            logger.info("DELETE (\(request.url?.path ?? ""))")
            return
        default:
            let message = String(data: body, encoding: .utf8) ?? "Unknown"
            logger.error("DELETE Error (\(request.url?.path ?? ""), \(httpResponse.statusCode)): \(message)")
            throw RemoteError.requestFailed(httpResponse.statusCode, message)
        }
    }

    public func move(path: String, to toPath: String) async throws {
        logger.warning("RemoteS3.move not implemented")
    }

    public func list(path: String, ignores: [String]) async throws -> [String: URL] {
        logger.warning("RemoteS3.list not implemented")
        return [:]
    }

    // MARK: - Private

    private func sign(request: URLRequest, data: Data, privateKey: PrivateKey) throws -> URLRequest {
        guard let url = request.url else {
            throw RemoteError.missingURL
        }
        let signature = AWSV4Signature(
            accessKey: accessKey,
            secretKey: secretKey,
            regionName: region
        )
        return try signature.sign(
            method: .init(rawValue: request.httpMethod ?? "PUT") ?? .put,
            url: url,
            data: data,
            headers: request.allHTTPHeaderFields ?? [:]
        )
    }
}

struct AWSV4Signature {
    let accessKey: String
    let secretKey: String
    let regionName: String

    enum Method: String {
        case get = "GET"
        case put = "PUT"
        case delete = "DELETE"
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case missingURL

        var description: String {
            switch self {
            case .missingURL:
                "Missing URL"
            }
        }
    }

    func sign(method: Method, bucket: String, params: [String: String] = [:]) throws -> URLRequest {
        var urlComponents = URLComponents(string: "https://s3.\(regionName).amazonaws.com/\(bucket)")!
        urlComponents.queryItems = params.map { URLQueryItem(name: $0, value: $1) }
        guard let url = urlComponents.url else {
            throw Error.missingURL
        }
        return try sign(method: method, url: url)
    }

    func sign(method: Method, url: URL, data: Data? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        let now = Date()
        let amzDate = Self.dateFormatter.string(from: now)
        let dateStamp = Self.dayFormatter.string(from: now)

        let canonicalURI = url.path

        // Parameters must be ordered by name
        let canonicalQueryString: String
        if let query = url.query {
            canonicalQueryString = query
                .components(separatedBy: "&")
                .map { param -> URLQueryItem in
                    let parts = param.components(separatedBy: "=")
                    return URLQueryItem(
                        name: parts[0],
                        value: parts.count > 1 ? parts[1] : nil
                    )
                }
                .sorted { $0.name < $1.name }
                .map { item in
                    if let value = item.value {
                        return "\(item.name)=\(value)"
                    }
                    return item.name
                }
                .joined(separator: "&")
        } else {
            canonicalQueryString = ""
        }

        let dataHash: String
        if let data, !data.isEmpty {
            dataHash = sha256(data).hexEncodedString()
        } else {
            dataHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" // empty string
        }

        var awsHeaders = headers
        awsHeaders["host"] = url.host ?? ""
        awsHeaders["x-amz-content-sha256"] = dataHash
        awsHeaders["x-amz-date"] = amzDate

        let canonicalHeaders = awsHeaders
            .map { "\($0.key.lowercased()):\($0.value)\n" }
            .sorted()
            .joined()

        let signedHeaders = canonicalHeaders
            .components(separatedBy: "\n")
            .dropLast()
            .map { $0.components(separatedBy: ":")[0] }
            .joined(separator: ";")

        let canonicalRequest = [
            method.rawValue,
            canonicalURI,
            canonicalQueryString,
            canonicalHeaders,
            signedHeaders,
            dataHash
        ].joined(separator: "\n")

        // String to sign
        let algorithm = "AWS4-HMAC-SHA256"
        let scope = "\(dateStamp)/\(regionName)/s3/aws4_request"
        let stringToSign = [
            algorithm,
            amzDate,
            scope,
            sha256(canonicalRequest.data(using: .utf8)!).hexEncodedString()
        ].joined(separator: "\n")

        // Signature calculation
        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: dateStamp.data(using: .utf8)!)
        let kRegion = hmac(key: kDate, data: regionName.data(using: .utf8)!)
        let kService = hmac(key: kRegion, data: "s3".data(using: .utf8)!)
        let kSigning = hmac(key: kService, data: "aws4_request".data(using: .utf8)!)
        let signature = hmac(key: kSigning, data: stringToSign.data(using: .utf8)!).hexEncodedString()

        // Authorization header
        let authorizationHeader = [
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope)",
            "SignedHeaders=\(signedHeaders)",
            "Signature=\(signature)"
        ].joined(separator: ", ")

        // Request with required headers
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(dataHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Add headers
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        return request
    }

    static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyyMMdd"
        return fmt
    }()

    static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return fmt
    }()

    private func sha256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return Data(hash)
    }

    private func hmac(key: Data, data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBuffer in
            data.withUnsafeBytes { dataBuffer in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBuffer.baseAddress,
                    keyBuffer.count,
                    dataBuffer.baseAddress,
                    dataBuffer.count,
                    &hash
                )
            }
        }
        return Data(hash)
    }
}

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
