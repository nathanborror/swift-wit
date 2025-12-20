import Foundation
import OSLog
import Compression
import CryptoKit

private let logger = Logger(subsystem: "ObjectStore", category: "Wit")

public actor Objects {

    public enum Error: Swift.Error {
        case invalidObjectFormat
    }

    public let remote: Remote

    private let objectsPath: String

    public init(remote: Remote, objectsPath: String) {
        self.remote = remote
        self.objectsPath = objectsPath.trimmingSlashes()
    }

    // MARK: Store

    public func store(commit: Commit, privateKey: Remote.PrivateKey?) async throws -> String {
        let data = try commit.encode()
        let hash = computeHash(data)
        let path = objectPath(.init(hash: hash, kind: .commit))
        try await remote.put(path: path, data: data, directoryHint: .notDirectory, privateKey: privateKey)
        return hash
    }

    public func store(tree: Tree, privateKey: Remote.PrivateKey?) async throws -> String {
        let data = try tree.encode()
        let hash = computeHash(data)
        let path = objectPath(.init(hash: hash, kind: .tree))
        try await remote.put(path: path, data: data, directoryHint: .notDirectory, privateKey: privateKey)
        return hash
    }

    public func store(blob data: Data, privateKey: Remote.PrivateKey?) async throws -> String {
        let hash = computeHash(data)
        let path = objectPath(.init(hash: hash, kind: .blob))
        try await remote.put(path: path, data: data, directoryHint: .notDirectory, privateKey: privateKey)
        return hash
    }

    public func store(binary data: Data, ext: String, privateKey: Remote.PrivateKey?) async throws -> String {
        let hash = computeHash(data)
        let path = objectPath(.init(hash: hash, kind: .binary))
        try await remote.put(path: "\(path).\(ext)", data: data, directoryHint: .notDirectory, privateKey: privateKey)
        return "\(hash).\(ext)"
    }

    // MARK: Deletion

    public func deleteBinary(hash: String, privateKey: Remote.PrivateKey?) async throws {
        let path = objectPath(.init(hash: hash, kind: .binary))
        try await remote.delete(path: path, privateKey: privateKey)
    }

    // MARK: Retrieve

    public func retrieve(commit hash: String) async throws -> Commit {
        let path = objectPath(.init(hash: hash, kind: .commit))
        let data = try await remote.get(path: path)
        return try Commit(data: data)
    }

    public func retrieve(tree hash: String) async throws -> Tree {
        let path = objectPath(.init(hash: hash, kind: .tree))
        let data = try await remote.get(path: path)
        return try Tree(data: data)
    }

    public func retrieve(blob hash: String) async throws -> Data {
        let path = objectPath(.init(hash: hash, kind: .blob))
        return try await remote.get(path: path)
    }

    public func retrieve(binary hash: String) async throws -> Data {
        let path = objectPath(.init(hash: hash, kind: .binary))
        return try await remote.get(path: path)
    }

    public func retrieveFileReferencesRecursive(_ tree: Tree, path: String = "") async throws -> [String: File] {
        var files: [String: File] = [:]
        for entry in tree.entries {
            switch entry.mode {
            case .directory:
                let tree = try await retrieve(tree: entry.hash)
                if path.isEmpty {
                    let additional = try await retrieveFileReferencesRecursive(tree, path: entry.name)
                    files.merge(additional) { _, new in new }
                } else {
                    let additional = try await retrieveFileReferencesRecursive(tree, path: "\(path)/\(entry.name)")
                    files.merge(additional) { _, new in new }
                }

            case .executable, .normal, .symbolicLink:
                if path.isEmpty {
                    files[entry.name] = .init(path: entry.name, hash: entry.hash, mode: .normal)
                } else {
                    let filePath = "\(path)/\(entry.name)"
                    files[filePath] = .init(path: filePath, hash: entry.hash, mode: .normal)
                }
            }
        }
        return files
    }

    public func retrieveTreesRecursive(_ hash: String, path: String = "") async throws -> [String: Tree] {
        guard !hash.isEmpty else { return [:] }

        var out: [String: Tree] = [:]
        let tree = try await retrieve(tree: hash)
        out[path] = tree

        for entry in tree.entries where entry.mode == .directory {
            let subPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
            let trees = try await retrieveTreesRecursive(entry.hash, path: subPath)
            out.merge(trees) { (_, new) in new }
        }
        return out
    }

    public struct Key: Hashable, Sendable {
        public let hash: String
        public let kind: Kind

        public enum Kind: String, Sendable {
            case commit
            case tree
            case blob
            case binary
        }
    }

    /// Returns a set of hashes that are referenced by a given commit
    public func retrieveCommitKeys(_ hash: String) async throws -> Set<Key> {
        var seen = Set<Key>()
        var stack: [Key] = [.init(hash: hash, kind: .commit)]

        while let key = stack.popLast() {
            if seen.contains(key) { continue }
            seen.insert(key)

            switch key.kind {
            case .commit:
                if let commit = try? await retrieve(commit: key.hash) {
                    if let parentHash = commit.parent {
                        stack.append(.init(hash: parentHash, kind: .commit))
                    }
                    if !commit.tree.isEmpty {
                        stack.append(.init(hash: commit.tree, kind: .tree))
                    }
                }
            case .tree:
                if let tree = try? await retrieve(tree: key.hash) {
                    for entry in tree.entries {
                        switch entry.mode {
                        case .directory:
                            stack.append(.init(hash: entry.hash, kind: .tree))
                        case .executable, .normal, .symbolicLink:
                            stack.append(.init(hash: entry.hash, kind: .blob))
                        }
                    }
                }
            case .blob, .binary:
                continue
            }
        }
        return seen
    }

    // MARK: Existance

    public func exists(key: Key) async throws -> Bool {
        let path = objectPath(key)
        return try await remote.exists(path: path)
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
        guard fileSize > 0 else {
            let data = Data()
            return computeHash(data)
        }

        let fd = fileHandle.fileDescriptor
        guard let ptr = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, fd, 0) else {
            throw CocoaError(.fileReadUnknown)
        }
        guard ptr != MAP_FAILED else { throw CocoaError(.fileReadUnknown) }

        let data = Data(bytesNoCopy: ptr, count: fileSize, deallocator: .custom { ptr, size in
            munmap(ptr, size)
        })
        return computeHash(data)
    }

    public func objectPath(_ key: Key) -> String {
        let dir = String(key.hash.prefix(2))
        let file = String(key.hash.dropFirst(2))

        var kind = ""
        switch key.kind {
        case .commit:
            kind = "commits"
        case .tree:
            kind = "trees"
        case .blob:
            kind = "blobs"
        case .binary:
            kind = "binaries"
        }

        return "\(objectsPath)/\(kind)/\(dir)/\(file)"
    }

    // MARK: Private

    func computeHash(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
