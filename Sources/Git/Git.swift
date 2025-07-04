import Foundation
import Compression
import CryptoKit

final class ObjectStorage {
    private let baseURL: URL
    private let compressionThreshold: Int
    private let useCompression: Bool

    public enum Error: Swift.Error {
        case objectNotFound
        case invalidObjectFormat
    }

    public init(url: URL, compressionThreshold: Int = 1024, useCompression: Bool = true) throws {
        self.baseURL = url
        self.compressionThreshold = compressionThreshold
        self.useCompression = useCompression
        try createDirectoryIfNeeded(at: self.baseURL)
    }

    public func store(_ object: Storable) throws -> String {
        let objectHash = computeHash(object)
        let objectURL = objectURL(objectHash)

        let objectDirURL = objectURL.deletingLastPathComponent()
        try createDirectoryIfNeeded(at: objectDirURL)

        var objectData = encode(object)
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

    public func retrieve(_ hash: String) throws -> Object {
        let objectURL = objectURL(hash)
        guard exists(url: objectURL) else {
            throw Error.objectNotFound
        }

        var data = try Data(contentsOf: objectURL)

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
        return try decode(data)
    }

    public func exists(hash: String) -> Bool {
        let objectURL = objectURL(hash)
        return exists(url: objectURL)
    }

    public func exists(url: URL) -> Bool {
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func computeHash(_ object: Storable) -> String {
        let header = "\(object.type.rawValue) \(object.content.count)"
        let headerData = header.data(using: .utf8)!

        var data = Data()
        data.append(headerData)
        data.append(object.content)

        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // Private

    private func objectURL(_ hash: String) -> URL {
        let dir = String(hash.prefix(2))
        let file = String(hash.dropFirst(2))
        return baseURL.appending(path: dir).appending(path: file)
    }

    private func encode(_ object: Storable) -> Data {
        let header = "\(object.type.rawValue) \(object.content.count)\0"
        let headerData = header.data(using: .utf8)!

        var data = Data()
        data.append(headerData)
        data.append(object.content)

        return data
    }

    private func decode(_ data: Data) throws -> Object {
        guard let nullIndex = data.firstIndex(of: 0) else {
            throw Error.invalidObjectFormat
        }

        let headerData = data[..<nullIndex]
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw Error.invalidObjectFormat
        }

        let parts = header.split(separator: " ")
        guard parts.count == 2,
              let kind = Object.Kind(rawValue: String(parts[0])),
              let size = Int(parts[1]) else {
            throw Error.invalidObjectFormat
        }

        let contentStart = data.index(after: nullIndex)
        let content = data[contentStart...]

        return .init(kind: kind, content: content, size: size)
    }

    private func shouldCompress(compressionBytes: Int, originalBytes: Int) -> Bool {
        Double(compressionBytes) < Double(originalBytes) * 0.9 // Greater than 10% savings?
    }

    private func createDirectoryIfNeeded(at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
}

// MARK: - Types

public struct Object {
    public let kind: Kind
    public let content: Data
    public let size: Int

    public enum Kind: String {
        case blob = "blob"
        case tree = "tree"
        case commit = "commit"
    }
}

public protocol Storable {
    var type: Object.Kind { get }
    var content: Data { get }
}

public struct Blob: Storable {
    public let type = Object.Kind.blob
    public let content: Data

    public init(content: Data) {
        self.content = content
    }

    public init(string: String) {
        self.content = string.data(using: .utf8) ?? Data()
    }
}

public struct Tree: Storable {
    public let type = Object.Kind.tree
    public let entries: [Entry]

    public var content: Data {
        let entries = entries.sorted { $0.name < $1.name }
        let content = entries.map { $0.formatted }.joined()
        return content.data(using: .utf8) ?? Data()
    }

    public struct Entry {
        public let mode: String
        public let name: String
        public let hash: String

        public var formatted: String {
            "\(mode) \(name)\0\(hash)"
        }
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }
}

public struct Commit: Storable {
    public let type = Object.Kind.commit
    public let tree: String
    public let parent: String
    public let author: String
    public let message: String
    public let timestamp: Date

    public var content: Data {
        var lines: [String] = []
        lines.append("tree \(tree)")

        if !parent.isEmpty {
            lines.append("parent: \(parent)")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = commitDateFormat
        let dateString = dateFormatter.string(from: timestamp)

        lines.append("author \(author) \(dateString)")
        lines.append("")
        lines.append(message)

        let content = lines.joined(separator: "\n")
        return content.data(using: .utf8) ?? Data()
    }
}

public let commitDateFormat = "yyyy-MM-dd HH:mm:ss Z"
