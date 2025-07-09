import Foundation
import Compression
import CryptoKit

public final class ObjectStore {
    public let baseURL: URL

    private let compressionThreshold: Int
    private let useCompression: Bool

    public enum Error: Swift.Error {
        case objectNotFound
        case invalidObjectFormat
        case pathTraversalAttempt
    }

    public init(baseURL: URL, compressionThreshold: Int = 1024, useCompression: Bool = true) throws {
        self.baseURL = baseURL
        self.compressionThreshold = compressionThreshold
        self.useCompression = useCompression
    }

    public func store(_ object: Storable) throws -> String {
        let objectHash = hash(for: object)
        let objectURL = try objectURL(objectHash)

        try FileManager.default.createDirectoryIfNeeded(objectURL)

        var objectData = object.encode()
        var isCompressed = false

        if useCompression && objectData.count > compressionThreshold {
            let nsData = objectData as NSData
            if let compressed = try? nsData.compressed(using: .zlib), shouldCompress(compressionBytes: compressed.count, originalBytes: objectData.count) {
                objectData = compressed as Data
                isCompressed = true
            }
        }

        var finalData = Data()
        finalData.append(isCompressed ? 0x01 : 0x00)
        finalData.append(objectData)

        try finalData.write(to: objectURL)
        return objectHash
    }

    public func retrieve<T: Storable>(_ hash: String, as type: T.Type) throws -> T {
        let object = try retrieve(hash)
        switch object.kind {
        case .blob:
            if type == Blob.self {
                return Blob(data: object.content) as! T
            }
        case .tree:
            if type == Tree.self {
                return Tree(data: object.content) as! T
            }
        case .commit:
            if type == Commit.self {
                return Commit(data: object.content) as! T
            }
        }
        throw Error.invalidObjectFormat
    }

    public func retrieve(_ hash: String) throws -> Object {
        var data = try retrieveData(hash)
        guard !data.isEmpty else {
            throw Error.invalidObjectFormat
        }

        let isCompressed = data[0] == 0x01
        data = data.dropFirst()

        if isCompressed {
            let nsData = data as NSData
            guard let decompressed = try? nsData.decompressed(using: .zlib) else {
                throw Error.invalidObjectFormat
            }
            data = decompressed as Data
        }
        guard let object = Object(data: data) else {
            throw Error.invalidObjectFormat
        }
        return object
    }

    public func retrieveData(_ hash: String) throws -> Data {
        let objectURL = try objectURL(hash)
        guard exists(url: objectURL) else {
            throw Error.objectNotFound
        }
        return try Data(contentsOf: objectURL)
    }

    public func exists(hash: String) throws -> Bool {
        let objectURL = try objectURL(hash)
        return exists(url: objectURL)
    }

    public func exists(url: URL) -> Bool {
        if let scheme = url.scheme, scheme == "file" {
            return FileManager.default.fileExists(atPath: url.path)
        } else {
            return true // TODO: Probably need perform a HEAD check and make this async
        }
    }

    /// Computes the SHA-256 hash for a `Storable` object, including a header with its type and content length.
    /// - Parameter object: The `Storable` object to hash. The object's type and content are both included in the hash calculation.
    /// - Returns: The SHA-256 hash as a lowercase hexadecimal string.
    ///
    /// The hash is computed over the concatenation of a header (`"<type> <size>"` encoded as UTF-8) and the object's content. This approach ensures
    /// that both the object's type and its content size are part of the hash, similar to how Git computes object hashes.
    public func hash(for object: Storable) -> String {
        let data = object.encode()
        return hashCompute(data)
    }

    /// Computes the SHA-256 hash of a file at the given URL using memory mapping for efficiency.
    /// - Parameter url: The URL of the file to hash.
    /// - Returns: The SHA-256 hash of the file contents as a lowercase hexadecimal string.
    /// - Throws: An error if the file cannot be opened, mapped, or read.
    ///
    /// This method uses `mmap` to map the file into memory, which is more efficient than reading the entire file into a buffer, especially for large files. If the file
    /// is empty, it returns the SHA-256 hash of empty data.
    public func hash(for url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0

        let header = "blob \(fileSize)\0"
        let headerData = header.data(using: .utf8)!

        guard fileSize > 0 else {
            var data = Data()
            data += headerData
            return hashCompute(data)
        }

        let fd = fileHandle.fileDescriptor
        guard let ptr = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, fd, 0) else {
            throw CocoaError(.fileReadUnknown)
        }
        guard ptr != MAP_FAILED else { throw CocoaError(.fileReadUnknown) }

        var data = Data()
        data += headerData
        data += Data(bytesNoCopy: ptr, count: fileSize, deallocator: .custom { ptr, size in
            munmap(ptr, size)
        })

        return hashCompute(data)
    }

    // MARK: Private

    func hashURL(_ hash: String) -> URL {
        let path = hashPath(hash)
        return baseURL.appending(path: path).standardizedFileURL
    }

    func hashPath(_ hash: String) -> String {
        let dir = String(hash.prefix(2))
        let file = String(hash.dropFirst(2))
        return "\(dir)/\(file)"
    }

    func hashCompute(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.hexString
    }

    func objectURL(_ hash: String) throws -> URL {
        let url = hashURL(hash)
        guard url.path.hasPrefix(baseURL.standardized.path) else {
            throw Error.pathTraversalAttempt
        }
        return url
    }

    func shouldCompress(compressionBytes: Int, originalBytes: Int) -> Bool {
        Double(compressionBytes) < Double(originalBytes) * 0.9 // Greater than 10% savings?
    }
}

extension Digest {

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
