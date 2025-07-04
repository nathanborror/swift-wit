import Foundation
import Compression
import CryptoKit

public let WIT_DIR_NAME = ".wit"
public let WIT_IGNORE: Set<String> = [WIT_DIR_NAME, ".DS_Store"]

public final class Client {
    let workingURL: URL
    let storage: ObjectStorage
    let ignored: Set<String>

    public init(workingURL: URL, ignorePaths: Set<String> = []) throws {
        self.workingURL = workingURL
        self.storage = try ObjectStorage(baseURL: workingURL.appending(path: WIT_DIR_NAME))
        self.ignored = ignorePaths.union(WIT_IGNORE)
    }

    func commit(message: String, author: String, timestamp: Date = .now, previousCommitHash: String = "") throws -> String {
        let previousCommit = try? storage.retrieve(previousCommitHash, as: Commit.self)
        let previousTreeHash = previousCommit?.tree ?? ""
        let previousTree = try? storage.retrieve(previousTreeHash, as: Tree.self)

        let changedFiles = detectChanges(previousTree: previousTree)

        var blobHashes: [String: String] = [:]

        for change in changedFiles {
            let fileURL = workingURL.appending(path: change.path)
            let fileData = try Data(contentsOf: fileURL)
            let blob = Blob(content: fileData)
            let hash = try storage.store(blob)
            blobHashes[change.path] = hash
        }

        // Build new tree structure
        let treeHash = try buildTree(from: workingURL, blobHashes: blobHashes)

        // Create commit
        let commit = Commit(
            tree: treeHash,
            parent: previousCommitHash,
            author: author,
            message: message,
            timestamp: timestamp
        )
        return try storage.store(commit)
    }

    // Private

    private func buildTree(from directory: URL, blobHashes: [String: String]) throws -> String {
        var entries: [Tree.Entry] = []
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        for item in contents {
            let name = item.lastPathComponent
            guard !shouldIgnore(path: name) || !name.hasPrefix(".") else { continue }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                let subTreeHash = try buildTree(from: item, blobHashes: blobHashes)
                entries.append(.init(mode: "040000", name: name, hash: subTreeHash))
            } else {
                let relativePath = item.path.replacingOccurrences(of: workingURL.path+"/", with: "")
                if let blobHash = blobHashes[relativePath] {
                    entries.append(.init(mode: "100644", name: name, hash: blobHash))
                }
            }
        }
        let tree = Tree(entries: entries)
        return try storage.store(tree)
    }

    private func detectChanges(previousTree: Tree?) -> [FileChange] {
        var changes: [FileChange] = []

        // Build a map of previous file states
        var previousFiles: [String: String] = [:]
        if let previousTree = previousTree {
            for entry in previousTree.entries {
                previousFiles[entry.name] = entry.hash
            }
        }

        // Scan current working directory
        if let enumerator = FileManager.default.enumerator(at: workingURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let relativePath = fileURL.path.replacingOccurrences(of: workingURL.path + "/", with: "")
                guard !shouldIgnore(path: relativePath) else { continue }
                guard let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile else {
                    continue
                }
                let fileData = try? Data(contentsOf: fileURL)
                if let data = fileData {
                    let blob = Blob(content: data)
                    let currentHash = storage.computeHash(blob)
                    let previousHash = previousFiles[relativePath]
                    if previousHash != currentHash {
                        changes.append(.init(path: relativePath, previousHash: previousHash, currentHash: currentHash))
                    }
                }
            }
        }

        return changes
    }

    private func shouldIgnore(path: String) -> Bool {
        if ignored.contains(path) {
            return true
        }
        let components = path.split(separator: "/")
        for component in components {
            if ignored.contains(String(component)) {
                return true
            }
        }
        return false
    }
}

public final class ObjectStorage {
    private let baseURL: URL
    private let compressionThreshold: Int
    private let useCompression: Bool

    public enum Error: Swift.Error {
        case objectNotFound
        case invalidObjectFormat
    }

    public init(baseURL: URL, compressionThreshold: Int = 1024, useCompression: Bool = true) throws {
        self.baseURL = baseURL
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

    // Encode

    private func encode(_ object: Storable) -> Data {
        let header = "\(object.type.rawValue) \(object.content.count)\0"
        let headerData = header.data(using: .utf8)!

        var data = Data()
        data.append(headerData)
        data.append(object.content)

        return data
    }

    // Decode

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
            let mode = String(content[currentIndex..<spaceIndex])

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
                        dateFormatter.dateFormat = commitDateFormat
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

public struct FileChange {
    let path: String
    let previousHash: String?
    let currentHash: String
}
