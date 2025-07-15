import Foundation
import OSLog
import CryptoKit

private let logger = Logger(subsystem: "Repo", category: "Wit")

public final class Repo {
    static let defaultPath = ".wild"
    static let defaultConfigPath = "\(defaultPath)/config"
    static let defaultObjectsPath = "\(defaultPath)/objects"
    static let defaultHeadPath = "\(defaultPath)/HEAD"
    static let defaultLogsPath = "\(defaultPath)/logs"

    public enum Error: Swift.Error {
        case missingHEAD
        case missingCommonAncestor
    }

    public enum Ref {
        case head
        case commit(String)
    }

    public enum Author {
        case current
        case name(String)
    }

    var url: URL
    var disk: Remote
    var objects: Objects
    var privateKey: Remote.PrivateKey?

    public init(url: URL, objectsPath: String? = nil, privateKey: Remote.PrivateKey? = nil) {
        self.url = url
        self.privateKey = privateKey
        self.disk = RemoteDisk(baseURL: url)
        self.objects = Objects(
            remote: disk,
            objectsPath: objectsPath ?? Self.defaultObjectsPath
        )
    }

    // MARK: Working with files

    func read(_ path: String) async throws -> Data {
        try await disk.get(path: path)
    }

    func write(_ string: String?, path: String) async throws {
        try await write(string?.data(using: .utf8), path: path)
    }

    func write(_ data: Data?, path: String) async throws {
        guard let data else { return }
        try await disk.put(path: path, data: data, mimetype: nil, privateKey: privateKey)
    }

    func delete(_ path: String) async throws {
        try await disk.delete(path: path, privateKey: privateKey)
    }

    // MARK: Start a working area

    /// Clone a repository into a new directory. This is a shallow clone, only copies objects recursively referenced by HEAD.
    public func clone(_ remote: Remote, bare: Bool = false) async throws {
        try await initialize()

        let remoteObjects = Objects(remote: remote, objectsPath: Self.defaultObjectsPath)
        let remoteHeadData = try await remote.get(path: Self.defaultHeadPath)

        // Copy remote HEAD
        guard let remoteHead = String(data: remoteHeadData, encoding: .utf8) else {
            print("Remote HEAD missing")
            return
        }
        try await write(remoteHead, path: Self.defaultHeadPath)

        // Copy remote objects
        let remoteHashes = try await remoteObjects.retrieveHashes(remoteHead)
        for hash in remoteHashes {
            guard try await !objects.exists(hash) else {
                continue
            }
            let path = objects.hashPath(hash)
            let data = try await remote.get(path: path)
            try await write(data, path: path)
        }

        // Copy remote config
        if let remoteConfig = try? await remote.get(path: Self.defaultConfigPath) {
            try await write(remoteConfig, path: Self.defaultConfigPath)
        }

        // Copy remote logs
        if let remoteLogs = try? await remote.get(path: Self.defaultLogsPath) {
            try await write(remoteLogs, path: Self.defaultLogsPath)
        }

        if bare { return }

        // Create working directory
        let commit = try await objects.retrieve(remoteHead, as: Commit.self)
        try await buildWorkingDirectoryRecursively(commit.tree)
    }

    /// Create an empty repository.
    public func initialize(_ remote: Remote? = nil) async throws {
        let manager = FileManager.default

        try manager.touch(url/Self.defaultConfigPath)
        try manager.touch(url/Self.defaultHeadPath)
        try manager.touch(url/Self.defaultLogsPath)

        try manager.mkdir(url/Self.defaultObjectsPath)
        try manager.mkdir(url/".wild"/"remotes"/"origin")

        try await config(["core.version": "1.0"], remote: remote)
    }

    // MARK: Work on the current changes

    /// Add file contents to the index.
    public func stage(_ paths: String...) async throws {
        fatalError("not implemented")
    }

    // MARK: Examine history and state

    /// Show the working tree status.
    public func status(_ ref: Ref = .head) async throws -> [File] {
        var commitHash: String
        switch ref {
        case .head:
            commitHash = await retrieveHEAD()
        case .commit(let hash):
            commitHash = hash
        }

        // Gather file references within the commit
        var fileReferences: [String: File] = [:]
        if !commitHash.isEmpty {
            let commit = try await objects.retrieve(commitHash, as: Commit.self)
            let tree = try await objects.retrieve(commit.tree, as: Tree.self)
            fileReferences = try await objects.retrieveFileReferencesRecursive(tree)
        }

        // Gather file references within the working directory
        let fileReferencesCurrent = try await retrieveCurrentFileReferences()

        // Compare commit references with current files and find additions and modifications
        var out: [File] = []
        for (path, file) in fileReferencesCurrent {
            if let previousRef = fileReferences[path] {
                if previousRef.hash != file.hash {
                    out.append(file.apply(kind: .modified))
                }
            } else {
                out.append(file.apply(kind: .added))
            }
        }

        // Find deletions
        for (path, file) in fileReferences where fileReferencesCurrent[path] == nil {
            out.append(file.apply(kind: .deleted))
        }
        return out
    }

    /// Show commit logs.
    public func log() async throws -> [Log] {
        let contents = await retrieveLogFile()
        return contents.split(separator: "\n").map(String.init).map { LogDecoder().decode($0) }
    }

    // MARK: Grow and tweak common history

    /// Record changes to the repository.
    public func commit(_ message: String) async throws -> String {
        let head = await retrieveHEAD()
        var files = try await status()

        // Store blobs, generate hashes and update the file references before building new tree structure
        for (index, file) in files.enumerated() {
            guard file.state != .deleted else { continue }
            let data = try await disk.get(path: file.path)
            guard let blob = Blob(data: data) else { continue }
            let hash = try await objects.store(blob, privateKey: privateKey)
            files[index] = file.apply(hash: hash)
        }

        let parentCommit: Commit?
        if !head.isEmpty {
            parentCommit = try await objects.retrieve(head, as: Commit.self)
        } else {
            parentCommit = nil
        }

        // Build new tree structure
        let treeHash = try await updateTreesForChangedPaths(
            files: files,
            previousTreeHash: parentCommit?.tree ?? ""
        )

        // Create commit
        let commit = Commit(
            tree: treeHash,
            parent: head,
            message: message
        )
        let commitHash = try await objects.store(commit, privateKey: privateKey)

        // Update HEAD, log commit
        try await write(commitHash, path: Self.defaultHeadPath)
        try await log(commit: commit, hash: commitHash)

        return commitHash
    }

    /// Reapply commits on top of HEAD.
    public func rebase(_ remote: Remote) async throws -> String {
        try await fetch(remote)

        let head = await retrieveHEAD()
        let remoteHeadData = try await read(".wild/remotes/origin/HEAD")
        let remoteHead = String(data: remoteHeadData, encoding: .utf8) ?? ""

        guard !head.isEmpty, !remoteHead.isEmpty else {
            throw Error.missingHEAD
        }
        if head == remoteHead {
            logger.info("Nothing to rebase; already up-to-date")
            return head
        }

        // Determine common ancestor
        guard let ancestor = try await findCommonAncestor(localHead: head, remoteHead: remoteHead) else {
            throw Error.missingCommonAncestor
        }

        // Determine local-only commits (from localHead back to common ancestor, reversed)
        let localChain = try await ancestryPath(from: head, stopBefore: ancestor)
        if localChain.isEmpty {
            logger.info("Nothing to rebase; local has no unique commits")
            return head
        }

        // Replay (recommit) on top of remoteHead
        var newParent = remoteHead
        var rebasedCommits: [String] = []

        for hash in localChain.reversed() {
            var commit = try await objects.retrieve(hash, as: Commit.self)

            // TODO: Perform true commit
            // Commit may refer to an old tree; instead, you might want to re-stage files for each commit, or at minimum use their tree as-is.
            // If you want to re-apply diffs/patches (true rebase), that's more complex; for now we copy as if the tree is the working tree.
            commit.parent = newParent

            // Store modified commit
            let commitHash = try await objects.store(commit, privateKey: privateKey)
            newParent = commitHash
            rebasedCommits.append(commitHash)

            // Log commit
            try await log(commit: commit, hash: commitHash)
        }

        // Update local HEAD
        guard let finalHead = rebasedCommits.last, let finalHeadData = finalHead.data(using: .utf8) else {
            throw Error.missingHEAD
        }
        try await write(finalHeadData, path: Self.defaultHeadPath)

        logger.info("Rebased \(localChain.count) commits on top of remote, new HEAD: \(finalHead)")

        return finalHead
    }

    // MARK: Workflows

    /// Update remote along with associated objects.
    public func push(_ remote: Remote) async throws {
        let head = await retrieveHEAD()
        guard !head.isEmpty else {
            print("Nothing to push: local HEAD not set")
            return
        }

        // Get remote HEAD and all reachable hashes from local storage, compare with reachable hashes from remote
        // storage and determine what needs to be pushed.

        let remoteObjects = Objects(remote: remote, objectsPath: Self.defaultObjectsPath)
        let remoteHeadData = try? await remote.get(path: Self.defaultHeadPath)
        let remoteHead = String(data: remoteHeadData ?? Data(), encoding: .utf8) ?? ""

        let remoteReachable = (!remoteHead.isEmpty) ? try await remoteObjects.retrieveHashes(remoteHead) : []
        let localReachable = try await objects.retrieveHashes(head)
        let toPush = localReachable.subtracting(remoteReachable)

        if toPush.isEmpty {
            print("Nothing to push: remote up to date")
            return
        }

        for hash in toPush {
            let envelope = try await objects.retrieve(hash)
            let _ = try await remoteObjects.store(envelope, privateKey: privateKey)
        }

        // Update remote HEAD, log
        let currentHead = await retrieveHEAD()
        let currentLogs = await retrieveLogFile()
        try await remote.put(path: Self.defaultHeadPath, data: currentHead.data(using: .utf8)!, mimetype: nil, privateKey: privateKey)
        try await remote.put(path: Self.defaultLogsPath, data: currentLogs.data(using: .utf8)!, mimetype: nil, privateKey: privateKey)

        // Finished
        print("Pushed \(toPush.count) objects to \(remote)")
    }

    /// Fetch from and integrate with another repository.
    public func pull(_ remote: Remote) async throws {
        fatalError("not implemented")
    }

    /// Download objects from another repository.
    public func fetch(_ remote: Remote) async throws {
        // Download remote head
        let remoteHeadData = try await remote.get(path: Self.defaultHeadPath)
        let remoteHead = String(data: remoteHeadData, encoding: .utf8) ?? ""
        try await write(remoteHeadData, path: ".wild/remotes/origin/HEAD")

        // Local head
        let head = await retrieveHEAD()

        // Compare heads
        guard !remoteHead.isEmpty, head != remoteHead else { return }

        // Download remote objects
        let remoteObjects = Objects(remote: remote, objectsPath: Self.defaultObjectsPath)
        let remoteHashes = try await remoteObjects.retrieveHashes(remoteHead)
        for hash in remoteHashes {
            guard try await !objects.exists(hash) else {
                continue
            }
            let path = objects.hashPath(hash)
            let data = try await remote.get(path: path)
            try await write(data, path: path)
        }

        // Download remote logs
        if let remoteLogs = try? await remote.get(path: Self.defaultLogsPath) {
            try await write(remoteLogs, path: ".wild/remotes/origin/logs")
        }
    }

    // MARK: Configuration

    /// Returns the config file as a string dictionary.
    public func config() async throws -> [String: String] {
        let configData = try await disk.get(path: Self.defaultConfigPath)
        let config = String(data: configData, encoding: .utf8) ?? ""
        return ConfigDecoder().decode(config)
    }

    /// Writes the given values to the config file and optionally uploads it to the given remote.
    public func config(_ values: [String: String], remote: Remote? = nil) async throws {
        var config = try await config()
        config.merge(values) { _, new in new }

        let newConfig = ConfigEncoder().encode(config)
        let newConfigData = newConfig.data(using: .utf8)!
        try await disk.put(path: Self.defaultConfigPath, data: newConfigData, mimetype: nil, privateKey: nil)

        if let remote {
            try await remote.put(path: Self.defaultConfigPath, data: newConfigData, mimetype: nil, privateKey: privateKey)
        }
    }
}

// MARK: - Private

extension Repo {

    /// Returns the current HEAD or an empty string if the file is empty.
    func retrieveHEAD() async -> String {
        guard let data = try? await read(Self.defaultHeadPath) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Returns the full contents of a log file as a string.
    func retrieveLogFile() async -> String {
        guard let data = try? await read(Self.defaultLogsPath) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Returns a dictionary of file references for files in the working directory keyed with their path, ignoring any ignored files.
    func retrieveCurrentFileReferences(at path: String = "") async throws -> [String: File] {
        let files = try await disk.list(path: path)
        var out: [String: File] = [:]
        for (relativePath, url) in files {
            if let hash = try? objects.hash(for: url) {
                out[relativePath] = .init(path: relativePath, hash: hash, mode: .normal)
            }
        }
        return out
    }

    /// Encodes a Commit log message and appends it to the logs file.
    func log(commit: Commit, hash: String) async throws {
        let line = LogEncoder().encode(commit: commit, hash: hash) + "\n"
        guard let lineData = line.data(using: .utf8) else { return }
        guard let fileHandle = FileHandle(forUpdatingAtPath: (url/Self.defaultLogsPath).path) else {
            print("Log Error: missing `\(Self.defaultLogsPath)` file")
            return
        }
        defer { try? fileHandle.close() }
        do {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: lineData)
        } catch {
            print("Log Error: failed to append `\(error)`")
        }
    }

    // TODO: Review generated code
    func findCommonAncestor(localHead: String, remoteHead: String) async throws -> String? {
        // Collect all ancestors of remote
        var remoteAncestors = Set<String>()
        var stack: [String] = [remoteHead]
        while let hash = stack.popLast() {
            if hash.isEmpty || remoteAncestors.contains(hash) { continue }
            remoteAncestors.insert(hash)
            let commit = try? await objects.retrieve(hash, as: Commit.self)
            if let parent = commit?.parent { stack.append(parent) }
        }
        // Walk local chain, return first common commit
        var current = localHead
        while !current.isEmpty {
            if remoteAncestors.contains(current) { return current }
            let commit = try? await objects.retrieve(current, as: Commit.self)
            guard let parent = commit?.parent else { break }
            current = parent
        }
        return nil
    }

    // TODO: Review generated code
    func ancestryPath(from head: String, stopBefore base: String) async throws -> [String] {
        var out: [String] = []
        var curr = head
        while !curr.isEmpty && curr != base {
            out.append(curr)
            let commit = try? await objects.retrieve(curr, as: Commit.self)
            guard let parent = commit?.parent else { break }
            curr = parent
        }
        return out
    }

    // TODO: Review generated code
    func updateTreesForChangedPaths(files: [File], previousTreeHash: String) async throws -> String {
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
        let previousTreeCache = try await objects.retrieveTreesRecursive(previousTreeHash)

        // Build trees bottom-up
        return try await buildTreeRecursively(
            directory: "",
            changedSubitems: changesByDirectory,
            files: files,
            previousTreeCache: previousTreeCache
        )
    }

    // TODO: Review generated code
    func buildTreeRecursively(directory: String, changedSubitems: [String: Set<String>], files: [File], previousTreeCache: [String: Tree]) async throws -> String {

        // If this directory hasn't changed, reuse previous tree
        if changedSubitems[directory] == nil, let previousTree = previousTreeCache[directory] {
            let data = previousTree.encode()
            let header = objects.header(kind: previousTree.kind.rawValue, count: data.count)
            return objects.hashCompute(header+data)
        }

        var entries: [Tree.Entry] = []
        let directoryURL = directory.isEmpty ? url : (url/directory)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        for item in contents {
            let filename = item.lastPathComponent
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let isRegularFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            let isSymbolicLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            let relativePath = directory.isEmpty ? filename : "\(directory)/\(filename)"

            if isDirectory {
                // Recursively build or reuse subtree
                let subTreeHash = try await buildTreeRecursively(
                    directory: relativePath,
                    changedSubitems: changedSubitems,
                    files: files,
                    previousTreeCache: previousTreeCache
                )
                entries.append(.init(
                    mode: .directory,
                    name: filename,
                    hash: subTreeHash
                ))
            } else if isSymbolicLink {
                if let file = files.first(where: { $0.path == relativePath }), let hash = file.hash {
                    entries.append(.init(
                        mode: .symbolicLink,
                        name: filename,
                        hash: hash
                    ))
                } else if let previousTree = previousTreeCache[directory], let previousEntry = previousTree.entries.first(where: { $0.name == filename }) {
                    entries.append(previousEntry)
                }
            } else if isRegularFile {
                // Use new blob hash or get from previous tree
                if let file = files.first(where: { $0.path == relativePath }), let hash = file.hash {
                    entries.append(.init(
                        mode: .normal,
                        name: filename,
                        hash: hash
                    ))
                } else if let previousTree = previousTreeCache[directory], let previousEntry = previousTree.entries.first(where: { $0.name == filename }) {
                    entries.append(previousEntry)
                }
            }
        }

        let tree = Tree(entries: entries)
        return try await objects.store(tree, privateKey: privateKey)
    }

    /// Build a directory of files from the object store relative to the given tree hash. Recurse down the tree to build a complete directory structure.
    func buildWorkingDirectoryRecursively(_ treeHash: String, path: String = "") async throws {
        let tree = try await objects.retrieve(treeHash, as: Tree.self)
        for entry in tree.entries {
            switch entry.mode {
            case .directory:
                let path = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
                try await buildWorkingDirectoryRecursively(entry.hash, path: path)
            case .normal, .executable, .symbolicLink:
                let blob = try await objects.retrieve(entry.hash, as: Blob.self)
                let fileURL = url/path/entry.name
                try FileManager.default.mkdir(fileURL)
                try blob.content.write(to: fileURL)
            }
        }
    }
}
