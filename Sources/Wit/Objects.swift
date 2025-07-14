import Foundation
import OSLog
import Compression
import CryptoKit

private let logger = Logger(subsystem: "ObjectStore", category: "Wit")

public final class Objects {
    public let remote: Remote

    private let objectsPath: String
    private let compressionThreshold: Int
    private let useCompression: Bool

    public enum Error: Swift.Error {
        case invalidObjectFormat
    }

    public init(remote: Remote, objectsPath: String, compressionThreshold: Int = 1024, useCompression: Bool = true) {
        self.remote = remote
        self.objectsPath = objectsPath.trimmingSlashes()
        self.compressionThreshold = compressionThreshold
        self.useCompression = useCompression
    }

    // MARK: Store

    public func store(_ storable: any Storable, privateKey: Remote.PrivateKey?) async throws -> String {
        let envelope = Envelope(storable: storable)
        return try await store(envelope, privateKey: privateKey)
    }

    public func store(_ envelope: Envelope, privateKey: Remote.PrivateKey?) async throws -> String {
        var objectData = envelope.encode()
        let objectHash = hashCompute(objectData)
        let objectPath = hashPath(objectHash)

        var isCompressed = false
        if useCompression && objectData.count > compressionThreshold {
            let nsData = objectData as NSData
            if let compressed = try? nsData.compressed(using: .zlib), shouldCompress(compressionBytes: compressed.count, originalBytes: objectData.count) {
                objectData = compressed as Data
                isCompressed = true
            }
        }

        var storedData = Data()
        storedData.append(isCompressed ? 0x01 : 0x00)
        storedData.append(objectData)

        try await remote.put(path: objectPath, data: storedData, mimetype: nil, privateKey: privateKey)
        return objectHash
    }

    // MARK: Retrieve

    public func retrieve<T: Storable>(_ hash: String, as type: T.Type) async throws -> T {
        let envelope = try await retrieve(hash)
        switch envelope.kind {
        case .blob:
            if type == Blob.self {
                return Blob(data: envelope.content) as! T
            }
        case .tree:
            if type == Tree.self {
                return Tree(data: envelope.content) as! T
            }
        case .commit:
            if type == Commit.self {
                return Commit(data: envelope.content) as! T
            }
        }
        throw Error.invalidObjectFormat
    }

    public func retrieve(_ hash: String) async throws -> Envelope {
        var data = try await retrieveData(hash)
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

        guard let envelope = Envelope(data: data) else {
            throw Error.invalidObjectFormat
        }
        return envelope
    }

    public func retrieveData(_ hash: String) async throws -> Data {
        let objectPath = hashPath(hash)
        return try await remote.get(path: objectPath)
    }

    public func retrieveFileReferencesRecursive(_ tree: Tree, path: String = "") async throws -> [String: File] {
        var envelopes: [String: File] = [:]
        for entry in tree.entries {
            let envelope = try await retrieve(entry.hash)
            switch envelope.kind {
            case .blob:
                let path = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
                envelopes[path] = .init(path: path, hash: entry.hash, mode: .normal)
            case .tree:
                let tree = try await retrieve(entry.hash, as: Tree.self)
                let additional = try await retrieveFileReferencesRecursive(tree, path: entry.name)
                envelopes.merge(additional) { _, new in new }
            case .commit:
                continue
            }
        }
        return envelopes
    }

    public func retrieveTreesRecursive(_ hash: String, path: String = "") async throws -> [String: Tree] {
        guard !hash.isEmpty else { return [:] }

        var out: [String: Tree] = [:]
        let tree = try await retrieve(hash, as: Tree.self)
        out[path] = tree

        for entry in tree.entries where entry.mode == .directory {
            let subPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
            let trees = try await retrieveTreesRecursive(entry.hash, path: subPath)
            out.merge(trees) { (_, new) in new }
        }
        return out
    }

    public func retrieveHashes(_ hash: String) async throws -> Set<String> {
        var seen = Set<String>()
        var stack: [String] = [hash]

        while let hash = stack.popLast() {
            if seen.contains(hash) { continue }
            seen.insert(hash)

            if let commit = try? await retrieve(hash, as: Commit.self) {
                if !commit.tree.isEmpty {
                    stack.append(commit.tree)
                }
                if !commit.parent.isEmpty {
                    stack.append(commit.parent)
                }
            } else if let tree = try? await retrieve(hash, as: Tree.self) {
                for entry in tree.entries {
                    stack.append(entry.hash)
                }
            }
        }
        return seen
    }

    public func exists(_ hash: String) async throws -> Bool {
        let objectPath = hashPath(hash)
        return try await remote.exists(path: objectPath)
    }

    // MARK: Hashing

    /// Computes the SHA-256 hash of a file at the given URL using memory mapping for efficiency.
    ///
    /// This method uses `mmap` to map the file into memory, which is more efficient than reading the entire file into a buffer, especially for large files. If the file
    /// is empty, it returns the SHA-256 hash of empty data.
    public func hash(for url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        let fileHeader = header(kind: "blob", count: fileSize)

        guard fileSize > 0 else {
            var data = Data()
            data += fileHeader
            return hashCompute(data)
        }

        let fd = fileHandle.fileDescriptor
        guard let ptr = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, fd, 0) else {
            throw CocoaError(.fileReadUnknown)
        }
        guard ptr != MAP_FAILED else { throw CocoaError(.fileReadUnknown) }

        var data = Data()
        data += fileHeader
        data += Data(bytesNoCopy: ptr, count: fileSize, deallocator: .custom { ptr, size in
            munmap(ptr, size)
        })

        return hashCompute(data)
    }

    // MARK: Misc

    public func header(kind: String, count: Int) -> Data {
        "\(kind) \(count)\0".data(using: .utf8)!
    }

    // MARK: Private

    func hashPath(_ hash: String) -> String {
        let dir = String(hash.prefix(2))
        let file = String(hash.dropFirst(2))
        return "\(objectsPath)/\(dir)/\(file)"
    }

    func hashCompute(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func shouldCompress(compressionBytes: Int, originalBytes: Int) -> Bool {
        Double(compressionBytes) < Double(originalBytes) * 0.9 // Greater than 10% savings?
    }
}
