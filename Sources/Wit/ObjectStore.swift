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

        try initialize()
    }

    public func store(_ object: Storable) throws -> String {
        let objectHash = computeHash(object)
        let objectURL = try objectURL(objectHash)

        let objectDirURL = objectURL.deletingLastPathComponent()
        try createDirectoryIfNeeded(objectDirURL)

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
        let objectURL = try objectURL(hash)
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

    public func retrieve<T: Storable>(_ hash: String, as type: T.Type) throws -> T {
        let object = try retrieve(hash)
        switch object.kind {
        case .blob:
            if type == Blob.self {
                return Blob(content: object.content) as! T
            }
        case .tree:
            if type == Tree.self {
                return try decodeTree(object.content) as! T
            }
        case .commit:
            if type == Commit.self {
                return try decodeCommit(object.content) as! T
            }
        }
        throw Error.invalidObjectFormat
    }

    public func exists(hash: String) throws -> Bool {
        let objectURL = try objectURL(hash)
        return exists(url: objectURL)
    }

    public func exists(url: URL) -> Bool {
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Computes the SHA-256 hash for a `Storable` object, including a header with its type and content length.
    /// - Parameter object: The `Storable` object to hash. The object's type and content are both included in the hash calculation.
    /// - Returns: The SHA-256 hash as a lowercase hexadecimal string.
    ///
    /// The hash is computed over the concatenation of a header (`"<type> <size>"` encoded as UTF-8) and the object's content. This approach ensures
    /// that both the object's type and its content size are part of the hash, similar to how Git computes object hashes.
    public func computeHash(_ object: Storable) -> String {
        let header = "\(object.type.rawValue) \(object.content.count)"
        let headerData = header.data(using: .utf8)!

        var data = Data()
        data.append(headerData)
        data.append(object.content)

        let hash = SHA256.hash(data: data)
        return hash.hexString
    }

    /// Computes the SHA-256 hash of a file at the given URL using memory mapping for efficiency.
    /// - Parameter url: The URL of the file to hash.
    /// - Returns: The SHA-256 hash of the file contents as a lowercase hexadecimal string.
    /// - Throws: An error if the file cannot be opened, mapped, or read.
    ///
    /// This method uses `mmap` to map the file into memory, which is more efficient than reading the entire file into a buffer, especially for large files. If the file
    /// is empty, it returns the SHA-256 hash of empty data.
    public func computeHashMemoryMapped(_ url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0

        let header = "blob \(fileSize)"
        let headerData = header.data(using: .utf8)!

        guard fileSize > 0 else {
            var data = Data()
            data += headerData
            return SHA256.hash(data: data).hexString
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

        let hash = SHA256.hash(data: data)
        return hash.hexString
    }

    // MARK: Private

    private func initialize() throws {
        try createDirectoryIfNeeded(baseURL)
    }

    private func objectURL(_ hash: String) throws -> URL {
        let dir = String(hash.prefix(2))
        let file = String(hash.dropFirst(2))
        let url = baseURL.appending(path: dir).appending(path: file).standardizedFileURL
        guard url.path.hasPrefix(baseURL.standardized.path) else {
            throw Error.pathTraversalAttempt
        }
        return url
    }

    private func shouldCompress(compressionBytes: Int, originalBytes: Int) -> Bool {
        Double(compressionBytes) < Double(originalBytes) * 0.9 // Greater than 10% savings?
    }

    private func createDirectoryIfNeeded(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }

    // MARK: Encoders

    private func encode(_ object: Storable) -> Data {
        let header = "\(object.type.rawValue) \(object.content.count)\0"
        let headerData = header.data(using: .utf8)!

        var data = Data()
        data.append(headerData)
        data.append(object.content)
        return data
    }

    // MARK: Decoders

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

    private func decodeTree(_ data: Data) throws -> Tree {
        let content = String(data: data, encoding: .utf8) ?? ""
        var entries: [Tree.Entry] = []

        var currentIndex = content.startIndex

        while currentIndex < content.endIndex {
            // Parse mode (e.g., "100644")
            guard let spaceIndex = content[currentIndex...].firstIndex(of: " ") else { break }
            let modeRaw = String(content[currentIndex..<spaceIndex])
            guard let mode = Mode(rawValue: modeRaw) else { break }

            // Parse name
            currentIndex = content.index(after: spaceIndex)
            guard let nullIndex = content[currentIndex...].firstIndex(of: "\0") else { break }
            let name = String(content[currentIndex..<nullIndex])

            // Parse hash (32 bytes = 64 hex characters for SHA-256)
            currentIndex = content.index(after: nullIndex)
            let hashEndIndex = content.index(currentIndex, offsetBy: 64, limitedBy: content.endIndex) ?? content.endIndex
            let hash = String(content[currentIndex..<hashEndIndex])

            entries.append(Tree.Entry(mode: mode, name: name, hash: hash))

            currentIndex = hashEndIndex
        }
        return Tree(entries: entries)
    }

    private func decodeCommit(_ data: Data) throws -> Commit {
        guard let content = String(data: data, encoding: .utf8) else {
            throw Error.invalidObjectFormat
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var tree = ""
        var parent = ""
        var author = ""
        var timestamp = Date()
        var message = ""
        var messageStartIndex = 0

        for (index, line) in lines.enumerated() {
            if line.starts(with: "tree ") {
                tree = String(line.dropFirst(5))
            } else if line.starts(with: "parent: ") {
                parent = String(line.dropFirst(8))
            } else if line.starts(with: "author ") {
                let authorLine = String(line.dropFirst(7))
                // Parse author and timestamp
                if let lastSpaceIndex = authorLine.lastIndex(of: " ") {
                    let dateStartIndex = authorLine.index(before: lastSpaceIndex)
                    if let secondLastSpaceIndex = authorLine[..<dateStartIndex].lastIndex(of: " ") {
                        author = String(authorLine[..<secondLastSpaceIndex])
                        let dateString = String(authorLine[authorLine.index(after: secondLastSpaceIndex)...])

                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = Commit.dateFormat
                        timestamp = dateFormatter.date(from: dateString) ?? Date()
                    }
                }
            } else if line.isEmpty && messageStartIndex == 0 {
                messageStartIndex = index + 1
                break
            }
        }

        if messageStartIndex < lines.count {
            message = lines[messageStartIndex...].joined(separator: "\n")
        }

        return Commit(
            tree: tree,
            parent: parent,
            author: author,
            message: message,
            timestamp: timestamp
        )
    }
}

extension Digest {

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
