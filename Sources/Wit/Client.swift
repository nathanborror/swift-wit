import Foundation
import CryptoKit

public final class Client {

    public struct Configuration {
        public var localURL: URL
        public var remoteURL: URL
        public var remote: Remote
        public var ignore: Set<String>

        public init(localURL: URL = .documentsDirectory, remoteURL: URL? = nil, remote: Remote? = nil, ignore: Set<String>? = nil) {
            self.localURL = localURL
            self.remoteURL = remoteURL ?? .init(string: "http://localhost:8080")!
            self.remote = remote ?? RemoteLocalhost(baseURL: self.remoteURL)
            self.ignore = ignore ?? [".wild", ".DS_Store"]
        }
    }

    let configuration: Configuration

    var userID: String?
    var privateKey: PrivateKey?
    var remote: Remote?

    var localUserURL: URL?
    var localUserRepoDir: URL?
    var localStorage: ObjectStore?

    var remoteUserURL: URL?
    var remoteUserRepoDir: URL?
    var remoteStorage: ObjectStore?

    public enum Error: Swift.Error {
        case missingUserID
        case missingLocalEndpoint
        case missingLocalStorage
        case missingRemote
        case missingRemoteEndpoint
        case missingRemoteStorage
    }

    public init(configuration: Configuration = .init()) throws {
        self.configuration = configuration
        self.remote = configuration.remote
    }

    /// Registers a new user with the remote host by generating a user ID and private key that are stored on the client.
    @discardableResult
    public func register() async throws -> (String, PrivateKey) {
        guard let remote else {
            throw Error.missingRemote
        }
        let (userID, privateKey) = try await remote.register()
        try await register(userID: userID, privateKey: privateKey)
        return (userID, privateKey)
    }

    /// Registers a user with the client by setting the user ID and private key directly rather than through the remote host.
    public func register(userID: String, privateKey: PrivateKey) async throws {
        self.userID = userID
        self.privateKey = privateKey
        try await remote?.register(userID: userID, privateKey: privateKey)
        try initialize()
    }

    /// Initializes the client by setting the necessary properties and establishing critical local files.
    public func initialize() throws {
        guard let userID else {
            throw Error.missingUserID
        }
        localUserURL = configuration.localURL.appending(path: userID)
        localUserRepoDir = localUserURL!.appending(path: ".wild")
        localStorage = try ObjectStore(baseURL: localUserRepoDir!.appending(path: "objects"))

        remoteUserURL = configuration.remoteURL.appending(path: userID)
        remoteUserRepoDir = remoteUserURL!.appending(path: ".wild")
        remoteStorage = try ObjectStore(baseURL: remoteUserRepoDir!.appending(path: "objects"))

        for item in ["config", "HEAD", "manifest", "logs"] {
            let url = localUserRepoDir!.appending(path: item)
            try FileManager.default.createFileIfNeeded(url)
        }
    }

    /// Unregisters the user and nullifies the client. This is destructive by default — deletes the user directory on the remote host and locally.
    public func unregister(deleteLocal: Bool = true, deleteRemote: Bool = true) async throws {
        guard let userRootURL = localUserURL else {
            throw Error.missingLocalEndpoint
        }

        if deleteRemote {
            try await remote?.unregister()
        }
        if deleteLocal {
            try FileManager.default.removeItem(at: userRootURL)
        }

        userID = nil
        privateKey = nil

        localUserURL = nil
        localUserRepoDir = nil
        localStorage = nil

        remoteUserURL = nil
        remoteUserRepoDir = nil
        remoteStorage = nil
    }

    /// Returns the contents of a file for a given path, always scoped to the user folder.
    public func read(_ path: String) -> String? {
        guard let url = localUserURL?.appending(path: path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Locally writes the contents of a string to the given file path.
    public func write(_ input: String, to path: String) throws {
        try write(input.data(using: .utf8) ?? Data(), to: path)
    }

    /// Locally writes the data to the given file path.
    public func write(_ input: Data, to path: String) throws {
        guard let url = localUserURL?.appending(path: path) else {
            throw Error.missingLocalEndpoint
        }
        try FileManager.default.createDirectoryIfNeeded(url)
        try input.write(to: url, options: [.atomic])
    }

    /// Locally deletes the given file path.
    public func delete(_ path: String) throws {
        guard let url = localUserURL?.appending(path: path) else {
            throw Error.missingLocalEndpoint
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Returns the working directory status compared to a specific commit or HEAD.
    ///
    /// This method determines which files have been modified, added, or deleted relative to the provided commit hash. If no commit hash is specified, it
    /// compares to the current HEAD. The returned `Status` object lists the paths of changed files categorized by their change type.
    ///
    /// - Parameter commitHash: The commit hash to compare against. If `nil`, uses the current HEAD.
    /// - Returns: A `Status` object with arrays of modified, added, and deleted file paths.
    /// - Throws: An error if the commit cannot be retrieved.
    public func status(commitHash: String? = nil) throws -> Status {
        guard let localStorage else {
            throw Error.missingLocalStorage
        }
        let head = read(".wild/HEAD")
        let commitHash = commitHash ?? head ?? ""
        let commit = try localStorage.retrieve(commitHash, as: Commit.self)
        let changed = try treeFilesChanged(commit.tree)
        return .init(
            modified: changed.filter { $0.kind == .modified }.map { $0.path },
            added: changed.filter { $0.kind == .added }.map { $0.path },
            deleted: changed.filter { $0.kind == .deleted }.map { $0.path }
        )
    }

    /// Creates a new commit representing the current state of the working directory.
    ///
    /// This method identifies all files that have been added, modified, or deleted since the previous commit. It then writes a new tree and commit object to the
    /// object store. The HEAD and manifest are updated to reflect the new commit.
    ///
    /// - Parameters:
    ///   - message: The commit message describing the changes.
    ///   - author: The author of the commit.
    ///   - timestamp: The time of the commit (defaults to current time).
    ///   - previousCommitHash: The hash of the previous commit (if any). Defaults to an empty string.
    /// - Returns: The hash of the newly created commit.
    /// - Throws: An error if storing objects or writing metadata fails.
    @discardableResult
    public func commit(message: String, author: String, timestamp: Date = .now, previousCommitHash: String? = nil) throws -> String {
        guard let localStorage else {
            throw Error.missingLocalStorage
        }
        guard let localUserURL else {
            throw Error.missingLocalEndpoint
        }

        // Previous commit, if it exists
        let previousCommit: Commit?
        if let previousCommitHash {
            previousCommit = try? localStorage.retrieve(previousCommitHash, as: Commit.self)
        } else {
            previousCommit = nil
        }

        // Determine which files in the directory tree have changed
        var files = try treeFilesChanged(previousCommit?.tree)
        for (index, file) in files.enumerated() {
            if file.kind != .deleted {
                let fileURL = localUserURL.appending(path: file.path)
                let blob = try Blob(url: fileURL)
                let hash = try localStorage.store(blob)
                files[index] = file.apply(hash: hash)
            }
        }

        // Build new tree structure
        let treeHash = try updateTreesForChangedPaths(
            files: files,
            previousTreeHash: previousCommit?.tree ?? ""
        )

        // Create commit
        let commit = Commit(
            tree: treeHash,
            parent: previousCommitHash,
            author: author,
            message: message,
            timestamp: timestamp
        )
        let commitHash = try localStorage.store(commit)

        // Update HEAD
        try write(commitHash, to: ".wild/HEAD")

        // Update Manifest
        let manifest = try buildManifest(commitHash)
        try write(manifest, to: ".wild/manifest")

        // Append log
        try log(commitHash, commit: commit)

        return commitHash
    }

    /// Lists all files tracked in a given commit, or the current HEAD.
    ///
    /// For the specified commit hash (or HEAD if none provided), this returns a sorted array of `FileRef` objects representing all files stored in the
    /// commit's tree.
    ///
    /// - Parameter commitHash: The commit hash to inspect. If `nil`, uses the current HEAD.
    /// - Returns: An array of `FileRef` values for each tracked file, sorted by path.
    /// - Throws: An error if the commit or tree cannot be retrieved.
    public func tracked(commitHash: String? = nil) throws -> [FileRef] {
        guard let localStorage else {
            throw Error.missingLocalStorage
        }
        let head = read(".wild/HEAD")
        let commitHash = commitHash ?? head ?? ""
        if commitHash.isEmpty {
            return []
        }
        let commit = try localStorage.retrieve(commitHash, as: Commit.self)
        let files = try treeFiles(commit.tree, path: "")
        return files.values.sorted { $0.path < $1.path }
    }

    public func fetch() async throws {
        guard let localStorage else {
            throw Error.missingLocalStorage
        }
        guard let remoteStorage else {
            throw Error.missingRemoteStorage
        }
        guard let remote else {
            throw Error.missingRemote
        }

        let localHead = read(".wild/HEAD")
        let remoteHeadData = try await remote.get(path: ".wild/HEAD")
        let remoteHead = String(data: remoteHeadData, encoding: .utf8)

        guard let remoteHead, localHead != remoteHead else {
            return
        }

        let commitsToFetch = try reachableHashes(from: remoteHead, using: remoteStorage)
        for hash in commitsToFetch {
            if try !localStorage.exists(hash: hash) {
                let prefix = String(hash.prefix(2))
                let suffix = String(hash.dropFirst(2))
                let path = ".wild/objects/\(prefix)/\(suffix)"
                let data = try await remote.get(path: path)
                try write(data, to: path)
            }
        }

        try write(remoteHead, to: ".wild/HEAD")

//        guard let remoteHead = try? String(contentsOf: remoteHeadURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !remoteHead.isEmpty else {
//            print("Remote HEAD not found")
//            return
//        }
//        let remoteObjectStore = try ObjectStore(baseURL: remoteObjectsURL)
//        let commitsToFetch = try reachableHashes(from: remoteHead, using: remoteObjectStore)
//
//        for hash in commitsToFetch {
//            if try !storage.exists(hash: hash) {
//                let srcURL = remoteObjectsURL.appendingPathComponent(hash)
//                let dstURL = storage.baseURL.appendingPathComponent(hash)
//
//                let (data, etag) = try await remote.get(url: srcURL, etag: nil)
//                // Figure out what to store (e.g. Commit, Tree or Object)
//            }
//        }
    }

    public func push() async throws {
        guard let localStorage else {
            throw Error.missingLocalStorage
        }
        guard let remoteStorage else {
            throw Error.missingRemoteStorage
        }
        guard let remote else {
            throw Error.missingRemote
        }
        guard let head = read(".wild/HEAD"), !head.isEmpty else {
            print("Nothing to push: local HEAD not set")
            return
        }

        // Get remote HEAD and all reachable hashes from local storage, compare with reachable hashes from remote
        // storage and determine what needs to be pushed.

        let remoteHead = await remoteHead
        let remoteReachable = (remoteHead != nil && !remoteHead!.isEmpty) ? try reachableHashes(from: remoteHead!, using: remoteStorage) : []
        let localReachable = try reachableHashes(from: head, using: localStorage)
        let toPush = localReachable.subtracting(remoteReachable)
        if toPush.isEmpty {
            print("Nothing to push: remote up to date")
            return
        }

        for hash in toPush {
            let prefix = String(hash.prefix(2))
            let suffix = String(hash.dropFirst(2))
            let data = try localStorage.retrieveData(hash)
            _ = try await remote.put(path: ".wild/objects/\(prefix)/\(suffix)", data: data, mimetype: nil)
        }

        // Update remote HEAD
        _ = try await remote.put(path: ".wild/HEAD", data: head.data(using: .utf8)!, mimetype: nil)

        // Update remote manifest
        // let remoteManifestURL = remoteDirURL.appending(path: "manifest")
        print("update remote manifest not implemented")

        // Append log line(s)
        // let remoteLogsURL = remoteDirURL.appending(path: "logs")
        print("update remote logs not implemented")

        // Finished
        print("Pushed \(toPush.count) objects to \(remote)")
    }

    // MARK: Private

    var remoteHead: String? {
        get async {
            let data = try? await remote?.get(path: ".wild/HEAD")
            return (data != nil) ? String(data: data!, encoding: .utf8) : nil
        }
    }

    private func reachableHashes(from rootHash: String, using objectStore: ObjectStore) throws -> Set<String> {
        var seen = Set<String>()
        var stack: [String] = [rootHash]

        while let hash = stack.popLast() {
            if seen.contains(hash) { continue }
            seen.insert(hash)

            if let commit = try? objectStore.retrieve(hash, as: Commit.self) {
                if !commit.tree.isEmpty {
                    stack.append(commit.tree)
                }
                if let parent = commit.parent {
                    stack.append(parent)
                }
            } else if let tree = try? objectStore.retrieve(hash, as: Tree.self) {
                for entry in tree.entries {
                    stack.append(entry.hash)
                }
//            } else if let blob = try? objectStore.retrieve(hash, as: Blob.self) {
//                print("blob")
//            } else {
//                print("fuck")
            }
        }
        return seen
    }

    private func buildManifest(_ commitHash: String) throws -> String {
        let files = try tracked(commitHash: commitHash)
        return files
            .map { "\($0.mode) \($0.hash ?? "") \($0.path)" }
            .joined(separator: "\n")
    }

    private func treeFilesChanged(_ treeHash: String?) throws -> [FileRef] {
        guard let localUserURL else {
            throw Error.missingLocalEndpoint
        }
        var changes: [FileRef] = []

        // Build a map of previous file states
        let previousFiles = try treeFiles(treeHash)

        // Scan current working directory
        let currentFiles = try files(within: localUserURL)

        // Find additions and modifications
        for (path, fileRef) in currentFiles {
            if let previousFileRef = previousFiles[path] {
                if previousFileRef.hash != fileRef.hash {
                    changes.append(fileRef.apply(kind: .modified))
                }
            } else {
                changes.append(fileRef.apply(kind: .added))
            }
        }

        // Find deletions
        for (path, fileRef) in previousFiles where currentFiles[path] == nil {
            changes.append(fileRef.apply(kind: .deleted))
        }
        return changes
    }

    private func treeFiles(_ treeHash: String?, path: String = "") throws -> [String: FileRef] {
        guard let localStorage else {
            throw Error.missingLocalStorage
        }
        var out: [String: FileRef] = [:]
        guard let treeHash else { return out }
        let tree = try localStorage.retrieve(treeHash, as: Tree.self)
        for entry in tree.entries {
            let fullPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
            if entry.mode == .directory {
                let files = try treeFiles(entry.hash, path: fullPath)
                out.merge(files, uniquingKeysWith: { _, new in new })
            } else {
                out[fullPath] = .init(path: fullPath, hash: entry.hash, mode: entry.mode)
            }
        }
        return out
    }

    private func files(within url: URL) throws -> [String: FileRef] {
        guard let localStorage else {
            throw Error.missingLocalStorage
        }
        var out: [String: FileRef] = [:]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return out
        }
        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
            guard !shouldIgnore(path: relativePath) else { continue }
            guard let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile else {
                continue
            }
            if let hash = try? localStorage.hash(for: fileURL) {
                out[relativePath] = .init(path: relativePath, hash: hash, mode: .normal)
            }
        }
        return out
    }

    // TODO: Review — was generated
    private func updateTreesForChangedPaths(files: [FileRef], previousTreeHash: String) throws -> String {
        var changesByDirectory: [String: Set<String>] = [:]

        for file in files {
            let parts = file.path.split(separator: "/")
            var currentPath = ""

            // Mark all parent directories as changed
            for i in 0..<parts.count-1 {
                if !currentPath.isEmpty { currentPath += "/" }
                currentPath += parts[i]
                changesByDirectory[currentPath, default: []].insert(String(parts[i+1]))
            }

            // Root directory
            changesByDirectory["", default: []].insert(String(parts[0]))
        }

        // Load previous tree structure
        let previousTreeCache = try treeStructure(previousTreeHash)

        // Build trees bottom-up
        return try buildTreeRecursively(
            directory: "",
            changedSubitems: changesByDirectory,
            files: files,
            previousTreeCache: previousTreeCache
        )
    }

    // TODO: Review — was generated
    private func buildTreeRecursively(directory: String, changedSubitems: [String: Set<String>], files: [FileRef], previousTreeCache: [String: Tree]) throws -> String {
        guard let localStorage else {
            throw Error.missingLocalStorage
        }
        guard let localUserURL else {
            throw Error.missingLocalEndpoint
        }

        // If this directory hasn't changed, reuse previous tree
        if changedSubitems[directory] == nil, let previousTree = previousTreeCache[directory] {
            return localStorage.hash(for: previousTree)
        }

        var entries: [Tree.Entry] = []
        let directoryURL = directory.isEmpty ? localUserURL : localUserURL.appending(path: directory)

        let contents = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey])

        for item in contents {
            let name = item.lastPathComponent
            guard !shouldIgnore(path: name) && !name.hasPrefix(".") else { continue }

            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relativePath = directory.isEmpty ? name : "\(directory)/\(name)"

            if isDirectory {
                // Recursively build or reuse subtree
                let subTreeHash = try buildTreeRecursively(
                    directory: relativePath,
                    changedSubitems: changedSubitems,
                    files: files,
                    previousTreeCache: previousTreeCache
                )
                entries.append(.init(mode: .directory, name: name, hash: subTreeHash))
            } else {
                // Use new blob hash or get from previous tree
                if let file = files.first(where: { $0.path == relativePath }), let hash = file.hash {
                    entries.append(.init(mode: .normal, name: name, hash: hash))
                } else if let previousTree = previousTreeCache[directory],
                          let previousEntry = previousTree.entries.first(where: { $0.name == name }) {
                    entries.append(previousEntry)
                }
            }
        }

        let tree = Tree(entries: entries)
        return try localStorage.store(tree)
    }

    private func treeStructure(_ treeHash: String, path: String = "") throws -> [String: Tree] {
        guard let localStorage else {
            throw Error.missingLocalStorage
        }
        guard !treeHash.isEmpty else { return [:] }

        var out: [String: Tree] = [:]
        let tree = try localStorage.retrieve(treeHash, as: Tree.self)
        out[path] = tree

        for entry in tree.entries where entry.mode == .directory {
            let subPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
            let trees = try treeStructure(entry.hash, path: subPath)
            out.merge(trees) { (_, new) in new }
        }
        return out
    }

    private func shouldIgnore(path: String) -> Bool {
        if configuration.ignore.contains(path) {
            return true
        }
        for component in path.split(separator: "/").map(String.init) {
            if configuration.ignore.contains(component) {
                return true
            }
        }
        return false
    }

    private func log(_ commitHash: String, commit: Commit) throws {
        guard let localUserRepoDir else {
            throw Error.missingLocalEndpoint
        }
        let timestamp = Int(commit.timestamp.timeIntervalSince1970)
        let timezone = timezoneOffset(commit.timestamp)
        let message = "\(commitHash) \(commit.parent ?? EmptyHash) \(commit.author) \(timestamp) \(timezone) commit: \(commit.message)\n"

        if let fileHandle = FileHandle(forUpdatingAtPath: localUserRepoDir.appending(path: "logs").path) {
            defer { try? fileHandle.close() }
            do {
                try fileHandle.seekToEnd()
                if let data = message.data(using: .utf8) {
                    try fileHandle.write(contentsOf: data)
                }
            } catch {
                print("Failed to append: \(error)")
            }
        } else {
            do { // If file doesn't exist, create it with the line
                try message.write(to: localUserRepoDir.appending(path: "logs"), atomically: true, encoding: .utf8)
            } catch {
                print("Failed to create file: \(error)")
            }
        }
    }

    private func timezoneOffset(_ date: Date) -> String {
        let secondsFromGMT = TimeZone.current.secondsFromGMT(for: date)
        let hours = abs(secondsFromGMT) / 3600
        let minutes = (abs(secondsFromGMT) % 3600) / 60
        let sign = secondsFromGMT >= 0 ? "+" : "-"
        return String(format: "%@%02d%02d", sign, hours, minutes)
    }
}
