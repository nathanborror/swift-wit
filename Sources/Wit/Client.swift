import Foundation
import OSLog
import CryptoKit

private let logger = Logger(subsystem: "Client", category: "Wit")

public final class Client {

    var workingPath: String
    var privateKey: Remote.PrivateKey
    var ignore: Set<String> = [".wild", ".DS_Store"]

    let localBaseURL: URL
    let local: Remote
    let store: ObjectStore

    public enum Error: Swift.Error {
        case missingUserID
        case missingLocalEndpoint
        case missingLocalStorage
        case missingRemote
        case missingRemoteEndpoint
        case missingRemoteStorage
    }

    public init(workingPath: String, privateKey: Remote.PrivateKey) {
        self.workingPath = workingPath
        self.privateKey = privateKey

        self.localBaseURL = .documentsDirectory / workingPath
        self.local = RemoteDisk(baseURL: localBaseURL)
        self.store = ObjectStore(remote: local, objectsPath: ".wild/objects")

        try! initialize()
    }


    public func initialize() throws {
        let manager = FileManager.default
        let url = localBaseURL

        try manager.touch(url/".wild"/"config")
        try manager.touch(url/".wild"/"manifest")
        try manager.touch(url/".wild"/"logs"/"heads"/"main")
        try manager.touch(url/".wild"/"refs"/"heads"/"main")

        try manager.mkdir(url/".wild"/"objects")
        try manager.mkdir(url/".wild"/"logs"/"remotes")
        try manager.mkdir(url/".wild"/"refs"/"remotes")
    }

    public func read(_ path: String) async throws -> String? {
        let data = try await local.get(path: path)
        return String(data: data, encoding: .utf8)
    }

    public func write(_ text: String, path: String, mimetype: String? = nil) async throws {
        try await write(text.data(using: .utf8) ?? Data(), path: path)
    }

    public func write(_ data: Data, path: String, mimetype: String? = nil) async throws {
        try await local.put(path: path, data: data, mimetype: mimetype, privateKey: privateKey)
    }

    public func delete(_ path: String) async throws {
        try await local.delete(path: path, privateKey: privateKey)
    }

    /// Returns the working directory status compared to a specific commit or HEAD.
    ///
    /// This method determines which files have been modified, added, or deleted relative to the provided commit hash. If no commit hash is specified, it
    /// compares to the current HEAD. The returned `Status` object lists the paths of changed files categorized by their change type.
    public func status(commitHash: String? = nil) async throws -> Status {
        let head = try await read(".wild/refs/heads/main")
        let commitHash = commitHash ?? head ?? ""
        let commit = try await store.retrieve(commitHash, as: Commit.self)
        let changed = try await treeFilesChanged(commit.tree)
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
    public func commit(message: String, author: String, timestamp: Date = .now, previousCommitHash: String? = nil) async throws -> String {

        // Previous commit, if it exists
        let previousCommit: Commit?
        if let previousCommitHash {
            previousCommit = try? await store.retrieve(previousCommitHash, as: Commit.self)
        } else {
            previousCommit = nil
        }

        // Determine which files in the directory tree have changed
        var files = try await treeFilesChanged(previousCommit?.tree)
        for (index, file) in files.enumerated() {
            if file.kind != .deleted {
                let data = try await local.get(path: file.path)
                if let blob = Blob(data: data) {
                    let hash = try await store.store(blob, privateKey: privateKey)
                    files[index] = file.apply(hash: hash)
                } else {
                    logger.error("Error creating blob")
                }
            }
        }

        // Build new tree structure
        let treeHash = try await updateTreesForChangedPaths(
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
        let commitHash = try await store.store(commit, privateKey: privateKey)

        // Update HEAD
        try await write(commitHash, path: ".wild/refs/heads/main")

        // Update Manifest
        let manifest = try await buildManifest(commitHash)
        try await write(manifest, path: ".wild/manifest")

        // Append log
        try await log(commitHash, commit: commit)
        return commitHash
    }

    /// Lists all files tracked in a given commit, or the current HEAD.
    ///
    /// For the specified commit hash (or HEAD if none provided), this returns a sorted array of `FileRef` objects representing all files stored in the
    /// commit's tree.
    public func tracked(commitHash: String? = nil) async throws -> [FileRef] {
        let head = try? await local.get(path: ".wild/refs/heads/main")
        let commitHash = commitHash ?? String(data: head ?? Data(), encoding: .utf8) ?? ""
        if commitHash.isEmpty {
            return []
        }

        let commit = try await store.retrieve(commitHash, as: Commit.self)
        let files = try await treeFiles(commit.tree, path: "")
        return files.values.sorted { $0.path < $1.path }
    }

    public func fetch(remote: Remote) async throws {
        // Download remote head
        let remoteHeadData = try await remote.get(path: ".wild/refs/heads/main")
        let remoteHead = String(data: remoteHeadData, encoding: .utf8)
        try await write(remoteHeadData, path: ".wild/refs/remotes/origin/main")

        // Local head
        let localHead = try await read(".wild/refs/heads/main")

        // Compare heads
        guard let remoteHead, localHead != remoteHead else { return }

        // Download remote objects
        let remoteStore = ObjectStore(remote: remote, objectsPath: ".wild/objects")
        let remoteHashes = try await reachableHashes(from: remoteHead, using: remoteStore)
        for hash in remoteHashes {
            guard try await !store.exists(hash) else {
                continue
            }
            let hashPath = store.hashPath(hash)
            let path = ".wild/objects/\(hashPath)"
            let data = try await remote.get(path: path)
            try await write(data, path: path)
        }

        // Download remote logs
        if let remoteLogData = try? await remote.get(path: ".wild/logs/heads/main") {
            try await write(remoteLogData, path: ".wild/logs/remotes/origin/main")
        }
    }

    public func reset(remote: Remote) async throws {

        // Check if local HEAD is different from remote HEAD
        let remoteHeadData = try await remote.get(path: ".wild/refs/heads/main")
        let remoteHead = String(data: remoteHeadData, encoding: .utf8)
        let localHead = try  await read(".wild/refs/heads/main")
        guard let remoteHead, localHead != remoteHead else { return }

        // Fetch objects and update local HEAD to remote HEAD
        try await fetch(remote: remote)

        // TODO: Figure out state of remote HEAD
        // If it is behind then don't change the local HEAD, if it's ahead then change it.
        // Update local logs and manfest to reflect a changed local HEAD.

        // Set local HEAD to remote
        try await write(remoteHead, path: ".wild/refs/heads/main")
    }

    public func push(remote: Remote) async throws {
        guard let head = try await read(".wild/refs/heads/main"), !head.isEmpty else {
            print("Nothing to push: local HEAD not set")
            return
        }

        // Get remote HEAD and all reachable hashes from local storage, compare with reachable hashes from remote
        // storage and determine what needs to be pushed.

        let remoteStore = ObjectStore(remote: remote, objectsPath: ".wild/objects")
        let remoteHeadData = try? await remote.get(path: ".wild/refs/heads/main")
        let remoteHead = String(data: remoteHeadData ?? Data(), encoding: .utf8) ?? ""

        let remoteReachable = (!remoteHead.isEmpty) ? try await reachableHashes(from: remoteHead, using: remoteStore) : []
        let localReachable = try await reachableHashes(from: head, using: store)
        let toPush = localReachable.subtracting(remoteReachable)

        if toPush.isEmpty {
            print("Nothing to push: remote up to date")
            return
        }

        for hash in toPush {
            let envelope = try await store.retrieve(hash)
            let _ = try await remoteStore.store(envelope, privateKey: privateKey)
        }

        // Update remote HEAD
        _ = try await remote.put(path: ".wild/refs/heads/main", data: head.data(using: .utf8)!, mimetype: nil, privateKey: privateKey)

        // Update remote manifest
        // let remoteManifestURL = remoteDirURL/"manifest"
        print("update remote manifest not implemented")

        // Append log line(s)
        // let remoteLogsURL = remoteDirURL/"logs"
        print("update remote logs not implemented")

        // Finished
        print("Pushed \(toPush.count) objects to \(remote)")
    }

    // MARK: Private

    private func reachableHashes(from rootHash: String, using objectStore: ObjectStore) async throws -> Set<String> {
        var seen = Set<String>()
        var stack: [String] = [rootHash]

        while let hash = stack.popLast() {
            if seen.contains(hash) { continue }
            seen.insert(hash)

            if let commit = try? await store.retrieve(hash, as: Commit.self) {
                if !commit.tree.isEmpty {
                    stack.append(commit.tree)
                }
                if let parent = commit.parent {
                    stack.append(parent)
                }
            } else if let tree = try? await store.retrieve(hash, as: Tree.self) {
                for entry in tree.entries {
                    stack.append(entry.hash)
                }
            }
        }
        return seen
    }

    private func buildManifest(_ commitHash: String) async throws -> String {
        let files = try await tracked(commitHash: commitHash)
        return files
            .map { "\($0.mode) \($0.hash ?? "") \($0.path)" }
            .joined(separator: "\n")
    }

    private func treeFilesChanged(_ treeHash: String?) async throws -> [FileRef] {
        var changes: [FileRef] = []

        // Build a map of previous file states
        let previousFiles = try await treeFiles(treeHash)

        // Scan current working directory
        let currentFiles = try await files(within: "")

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

    private func treeFiles(_ treeHash: String?, path: String = "") async throws -> [String: FileRef] {
        var out: [String: FileRef] = [:]
        guard let treeHash else { return out }
        let tree = try await store.retrieve(treeHash, as: Tree.self)
        for entry in tree.entries {
            let fullPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
            if entry.mode == .directory {
                let files = try await treeFiles(entry.hash, path: fullPath)
                out.merge(files, uniquingKeysWith: { _, new in new })
            } else {
                out[fullPath] = .init(path: fullPath, hash: entry.hash, mode: entry.mode)
            }
        }
        return out
    }

    private func files(within path: String) async throws -> [String: FileRef] {
        let files = try await local.list(path: path)
        var out: [String: FileRef] = [:]
        for (relativePath, url) in files {
            guard !shouldIgnore(path: relativePath) else { continue }
            if let hash = try? store.hash(for: url) {
                out[relativePath] = .init(path: relativePath, hash: hash, mode: .normal)
            }
        }
        return out
    }

    // TODO: Review — was generated
    private func updateTreesForChangedPaths(files: [FileRef], previousTreeHash: String) async throws -> String {
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
        let previousTreeCache = try await treeStructure(previousTreeHash)

        // Build trees bottom-up
        return try await buildTreeRecursively(
            directory: "",
            changedSubitems: changesByDirectory,
            files: files,
            previousTreeCache: previousTreeCache
        )
    }

    // TODO: Review — was generated
    private func buildTreeRecursively(directory: String, changedSubitems: [String: Set<String>], files: [FileRef], previousTreeCache: [String: Tree]) async throws -> String {

        // If this directory hasn't changed, reuse previous tree
        if changedSubitems[directory] == nil, let previousTree = previousTreeCache[directory] {
            let data = previousTree.encode()
            let header = store.header(kind: previousTree.kind.rawValue, count: data.count)
            return store.hashCompute(header+data)
        }

        var entries: [Tree.Entry] = []
        let directoryURL = directory.isEmpty ? localBaseURL : (localBaseURL/directory)

        let contents = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey])

        for item in contents {
            let name = item.lastPathComponent
            guard !shouldIgnore(path: name) && !name.hasPrefix(".") else { continue }

            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relativePath = directory.isEmpty ? name : "\(directory)/\(name)"

            if isDirectory {
                // Recursively build or reuse subtree
                let subTreeHash = try await buildTreeRecursively(
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
        return try await store.store(tree, privateKey: privateKey)
    }

    private func treeStructure(_ treeHash: String, path: String = "") async throws -> [String: Tree] {
        guard !treeHash.isEmpty else { return [:] }

        var out: [String: Tree] = [:]
        let tree = try await store.retrieve(treeHash, as: Tree.self)
        out[path] = tree

        for entry in tree.entries where entry.mode == .directory {
            let subPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
            let trees = try await treeStructure(entry.hash, path: subPath)
            out.merge(trees) { (_, new) in new }
        }
        return out
    }

    private func shouldIgnore(path: String) -> Bool {
        if ignore.contains(path) {
            return true
        }
        for component in path.split(separator: "/").map(String.init) {
            if ignore.contains(component) {
                return true
            }
        }
        return false
    }

    private func log(_ commitHash: String, commit: Commit) async throws {
        let timestamp = Int(commit.timestamp.timeIntervalSince1970)
        let timezone = timezoneOffset(commit.timestamp)
        let message = "\(commitHash) \(commit.parent ?? EmptyHash) \(commit.author) \(timestamp) \(timezone) commit: \(commit.message)\n"

        if let fileHandle = FileHandle(forUpdatingAtPath: (localBaseURL/".wild"/"logs").path) {
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
            try await write(message, path: ".wild/logs/heads/main")
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
