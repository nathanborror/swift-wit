import Foundation
import OSLog
import CryptoKit

private let logger = Logger(subsystem: "Repo", category: "Wit")

public actor Repo {
    public static let defaultPath = ".wild"
    public static let defaultConfigPath = "\(defaultPath)/config"
    public static let defaultObjectsPath = "\(defaultPath)/objects"
    public static let defaultHeadPath = "\(defaultPath)/HEAD"
    public static let defaultLogsPath = "\(defaultPath)/logs"
    public static let defaultIgnorePath = ".ignore"

    public enum Error: Swift.Error {
        case missingHEAD
        case missingCommonAncestor
        case missingHash
    }

    public enum Ref: Sendable {
        case head
        case commit(String)
    }

    let diskURL: URL
    let disk: any Remote
    let objects: Objects
    let privateKey: Remote.PrivateKey?

    public init(path: String, objectsPath: String? = nil, privateKey: Remote.PrivateKey? = nil) {
        self.diskURL = URL.documentsDirectory.appending(path: path)
        self.privateKey = privateKey
        self.disk = RemoteDisk(baseURL: diskURL)
        self.objects = Objects(
            remote: disk,
            objectsPath: objectsPath ?? Self.defaultObjectsPath
        )
    }

    // MARK: Convenience

    public func commit(ref: Ref = .head) async throws -> (String, Commit) {
        let hash = try await retrieveHash(ref: ref)
        let commit = try await objects.retrieve(hash, as: Commit.self)
        return (hash, commit)
    }

    public func tree(hash: String) async throws -> (String, Tree) {
        let tree = try await objects.retrieve(hash, as: Tree.self)
        return (hash, tree)
    }

    public func envelope(hash: String) async throws -> Envelope {
        try await objects.retrieve(hash)
    }

    // MARK: Working with files

    public func read(_ path: String) async throws -> Data {
        try await disk.get(path: path)
    }

    public func write(_ string: String?, path: String) async throws {
        guard let string else { return }
        try await write(string.data(using: .utf8), path: path)
    }

    public func write(_ data: Data?, path: String, directoryHint: URL.DirectoryHint = .notDirectory) async throws {
        try await disk.put(path: path, data: data, directoryHint: directoryHint, privateKey: privateKey)
    }

    public func move(_ path: String, to toPath: String) async throws {
        try await disk.move(path: path, to: toPath)
    }

    public func delete(_ path: String) async throws {
        try await disk.delete(path: path, privateKey: privateKey)
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: diskURL.appending(path: path).path)
    }

    public func existsAsDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let _ = FileManager.default.fileExists(atPath: diskURL.appending(path: path).path, isDirectory: &isDir)
        return isDir.boolValue
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

        // Copy necessary files
        for path in [
            Self.defaultConfigPath,
            Self.defaultLogsPath,
            Self.defaultIgnorePath,
        ] {
            if let data = try? await remote.get(path: path) {
                try await write(data, path: path)
            }
        }

        // Copy remote objects
        let remoteHashes = try await remoteObjects.retrieveHashes(remoteHead)
        for hash in remoteHashes {
            guard try await !objects.exists(hash) else {
                continue
            }
            let path = await objects.hashPath(hash)
            let data = try await remote.get(path: path)
            try await write(data, path: path)
        }

        if bare { return }

        // Create working directory
        let commit = try await objects.retrieve(remoteHead, as: Commit.self)
        try await buildWorkingDirectoryRecursively(commit.tree)
    }

    /// Create an empty repository.
    public func initialize(_ remote: Remote? = nil) async throws {
        let manager = FileManager.default

        try manager.touch(diskURL/Self.defaultConfigPath)
        try manager.touch(diskURL/Self.defaultHeadPath)
        try manager.touch(diskURL/Self.defaultLogsPath)

        try manager.mkdir(diskURL/Self.defaultObjectsPath)
        try manager.mkdir(diskURL/".wild"/"remotes"/"origin")

        // Set current version
        try await configMerge(
            path: Self.defaultConfigPath,
            values: ["core": .dictionary(["version": "1.0"])],
            remote: remote
        )
    }

    // MARK: Examine history and state

    /// Show the working tree status.
    public func status(_ ref: Ref = .head) async throws -> [File] {

        // Gather file references within the commit
        let fileReferences: [String: File]
        if let commitHash = try? await retrieveHash(ref: ref) {
            let commit = try await objects.retrieve(commitHash, as: Commit.self)
            let tree = try await objects.retrieve(commit.tree, as: Tree.self)
            fileReferences = try await objects.retrieveFileReferencesRecursive(tree)
        } else {
            fileReferences = [:]
        }

        // Gather file references within the working directory
        let fileReferencesCurrent = try await retrieveCurrentFileReferences()

        // Compare commit references with current files and find additions and modifications
        var out: [File] = []
        for (path, file) in fileReferencesCurrent {
            if let previousRef = fileReferences[path] {
                if previousRef.hash != file.hash {
                    out.append(file.apply(state: .modified, previousHash: previousRef.hash))
                }
            } else {
                out.append(file.apply(state: .added, previousHash: nil))
            }
        }

        // Find deletions
        for (path, file) in fileReferences where fileReferencesCurrent[path] == nil {
            out.append(file.apply(state: .deleted, previousHash: nil))
        }
        return out
    }

    public func logs() async throws -> [Log] {
        guard let contents = await retrieveCommitLogFile() else {
            return []
        }
        return contents.split(separator: "\n").map(String.init).map { LogDecoder().decode($0) }
    }

    // MARK: Grow and tweak common history

    /// Record changes to the repository.
    @discardableResult
    public func commit(_ message: String) async throws -> String {
        let head = await HEAD()
        var files = try await status()

        // Store blobs, generate hashes and update the file references before building new tree structure
        for (index, file) in files.enumerated() {
            guard file.state != .deleted else { continue }
            let data = try await disk.get(path: file.path)
            guard let blob = try? Blob(data: data) else { continue }
            let hash = try await objects.store(blob, privateKey: privateKey)
            files[index] = file.apply(hash: hash)
        }

        let parentCommit: Commit?
        if let head {
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
    @discardableResult
    public func rebase(_ remote: Remote) async throws -> String {
        try await fetch(remote)

        let head = await HEAD()
        let remoteHeadData = try await read(".wild/remotes/origin/HEAD")
        let remoteHead = String(data: remoteHeadData, encoding: .utf8)

        guard let head, let remoteHead else {
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

        // Get the file state at the remote HEAD
        let remoteCommit = try await objects.retrieve(remoteHead, as: Commit.self)
        let remoteTree = try await objects.retrieve(remoteCommit.tree, as: Tree.self)
        var currentFiles = try await objects.retrieveFileReferencesRecursive(remoteTree)

        // Replay (recommit) on top of remoteHead
        var newParent = remoteHead
        var rebasedCommits: [String] = []

        for hash in localChain.reversed() {
            let commit = try await objects.retrieve(hash, as: Commit.self)

            // Get the changes introduced by this commit
            let commitTree = try await objects.retrieve(commit.tree, as: Tree.self)
            let commitFiles = try await objects.retrieveFileReferencesRecursive(commitTree)

            let parentFiles: [String: File]
            if let parent = commit.parent {
                let parentCommit = try await objects.retrieve(parent, as: Commit.self)
                let parentTree = try await objects.retrieve(parentCommit.tree, as: Tree.self)
                parentFiles = try await objects.retrieveFileReferencesRecursive(parentTree)
            } else {
                parentFiles = [:]
            }

            // Apply changes from this commit to current state
            for (path, file) in commitFiles {
                currentFiles[path] = file
            }

            // Remove files that were deleted in this commit
            for (path, _) in parentFiles where commitFiles[path] == nil {
                currentFiles.removeValue(forKey: path)
            }

            // Build new tree with merged changes
            let mergedTreeHash = try await buildTreeFromFiles(currentFiles)

            let rebasedCommit = Commit(
                tree: mergedTreeHash,
                parent: newParent,
                message: commit.message
            )
            let rebasedCommitHash = try await objects.store(rebasedCommit, privateKey: privateKey)
            newParent = rebasedCommitHash
            rebasedCommits.append(rebasedCommitHash)

            try await log(commit: rebasedCommit, hash: rebasedCommitHash)
        }

        // Update local HEAD
        guard let finalHead = rebasedCommits.last, let finalHeadData = finalHead.data(using: .utf8) else {
            throw Error.missingHEAD
        }
        try await write(finalHeadData, path: Self.defaultHeadPath)

        // Update working directory to reflect new HEAD
        let finalCommit = try await objects.retrieve(finalHead, as: Commit.self)
        try await buildWorkingDirectoryRecursively(finalCommit.tree)

        logger.info("Rebased \(localChain.count) commits on top of remote, new HEAD: \(finalHead)")

        return finalHead
    }

    // MARK: Workflows

    /// Update remote along with associated objects.
    public func push(_ remote: Remote) async throws {
        guard let head = await HEAD() else {
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

        // Upload current HEAD, logs and config to remote
        for path in [
            Self.defaultConfigPath,
            Self.defaultLogsPath,
            Self.defaultHeadPath,
        ] {
            if let data = try? await read(path) {
                try await remote.put(path: path, data: data, directoryHint: .notDirectory, privateKey: privateKey)
            }
        }

        // Finished
        print("Pushed \(toPush.count) objects to \(remote)")
    }

    /// Fetch from and integrate with another repository.
    public func pull(_ remote: Remote) async throws {
        fatalError("not implemented")
    }

    /// Download objects from another repository.
    public func fetch(_ remote: Remote) async throws {

        // Copy remote config
        if let remoteConfig = try? await remote.get(path: Self.defaultConfigPath) {
            try await write(remoteConfig, path: Self.defaultConfigPath)
        }

        // Download remote head
        let remoteHeadData = try await remote.get(path: Self.defaultHeadPath)
        let remoteHead = String(data: remoteHeadData, encoding: .utf8) ?? ""
        try await write(remoteHeadData, path: ".wild/remotes/origin/HEAD")

        // Local head
        let head = await HEAD()

        // Compare heads
        guard !remoteHead.isEmpty, head != remoteHead else { return }

        // Download remote objects
        let remoteObjects = Objects(remote: remote, objectsPath: Self.defaultObjectsPath)
        let remoteHashes = try await remoteObjects.retrieveHashes(remoteHead)
        for hash in remoteHashes {
            guard try await !objects.exists(hash) else {
                continue
            }
            let path = await objects.hashPath(hash)
            let data = try await remote.get(path: path)
            try await write(data, path: path)
        }

        // Download remote logs
        if let remoteCommitLogs = try? await remote.get(path: Self.defaultLogsPath) {
            try await write(remoteCommitLogs, path: ".wild/remotes/origin/logs/commits")
        }
        if let remoteStatusLogs = try? await remote.get(path: Self.defaultLogsPath) {
            try await write(remoteStatusLogs, path: ".wild/remotes/origin/logs/status")
        }
    }

    // MARK: Configuration

    /// Returns the config file as a string dictionary.
    public func configRead(path: String) async throws -> Config {
        let configData = try await disk.get(path: path)
        let config = String(data: configData, encoding: .utf8) ?? ""
        return ConfigDecoder().decode(config)
    }

    /// Merges in the given config values to the config file and optionally uploads the file to the given remote.
    public func configMerge(path: String, values: [String: Config.Section], remote: Remote? = nil) async throws {
        let config = try? await configRead(path: path)
        var mergedSections = config?.sections ?? [:]

        for (section, newSection) in values {
            switch (mergedSections[section], newSection) {
            case (.dictionary(let oldDict), .dictionary(let newDict)):
                // Merge dictionaries, prefer new values
                mergedSections[section] = .dictionary(oldDict.merging(newDict) { _, new in new })
            default:
                // For arrays, or replacing an existing section of a different type, just set it
                mergedSections[section] = newSection
            }
        }

        try await configWrite(
            path: path,
            values: mergedSections,
            remote: remote
        )
    }

    /// Writes the given config values to the config file and optionally uploads the file to the given remote.
    public func configWrite(path: String, values: [String: Config.Section], remote: Remote? = nil) async throws {
        let newConfig = ConfigEncoder().encode(values)
        let newConfigData = newConfig.data(using: .utf8)!
        try await disk.put(path: path, data: newConfigData, directoryHint: .notDirectory, privateKey: nil)
        if let remote {
            try await remote.put(path: path, data: newConfigData, directoryHint: .notDirectory, privateKey: privateKey)
        }
    }

    // MARK: HEAD

    public func HEAD() async -> String? {
        guard let data = try? await read(Self.defaultHeadPath) else {
            return nil
        }
        if let hash = String(data: data, encoding: .utf8) {
            return hash.isEmpty ? nil : hash
        }
        return nil
    }
}

// MARK: - Private

extension Repo {

    func retrieveHash(ref: Ref) async throws -> String {
        switch ref {
        case .head:
            guard let hash = await HEAD() else {
                throw Error.missingHash
            }
            return hash
        case .commit(let hash):
            return hash
        }
    }

    func retrieveCommitLogFile() async -> String? {
        guard let data = try? await read(Self.defaultLogsPath) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func retrieveIgnores() async -> [String]? {
        guard let data = try? await read(Self.defaultIgnorePath) else {
            return nil
        }
        let ignores = String(data: data, encoding: .utf8)
        return ignores?.split(separator: "\n").map(String.init)
    }

    /// Returns a dictionary of file references for files in the working directory keyed with their path, ignoring any ignored files.
    func retrieveCurrentFileReferences(at path: String = "") async throws -> [String: File] {
        let ignores = await retrieveIgnores() ?? [".DS_Store", ".wild"]
        let files = try await disk.list(path: path, ignores: ignores)
        var out: [String: File] = [:]
        for (relativePath, url) in files {
            if let hash = try? await objects.hash(for: url) {
                out[relativePath] = .init(path: relativePath, hash: hash, mode: .normal)
            }
        }
        return out
    }

    /// Encodes a Commit log message and appends it to the logs file.
    func log(commit: Commit, hash: String) async throws {
        let line = LogEncoder().encode(commit: commit, hash: hash) + "\n"
        try log(path: Self.defaultLogsPath, append: line)
    }

    /// Appends line to given log file.
    func log(path: String, append line: String) throws {
        guard let lineData = line.data(using: .utf8) else { return }
        guard let fileHandle = FileHandle(forUpdatingAtPath: (diskURL/path).path) else {
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
            let data = try previousTree.encode()
            let header = await objects.header(kind: previousTree.kind.rawValue, count: data.count)
            return await objects.hashCompute(header+data)
        }

        // Files to ignore
        let ignores = await retrieveIgnores() ?? [".DS_Store", ".wild"]

        var entries: [Tree.Entry] = []
        let directoryURL = directory.isEmpty ? diskURL : (diskURL/directory)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
        )

        let shouldIgnore: (String, [String]) -> Bool = { path, ignores in
            for ignore in ignores {
                if path.hasPrefix(ignore) {
                    return true
                }
            }
            return false
        }

        for item in contents {
            let filename = item.lastPathComponent
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let isRegularFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            let isSymbolicLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            let relativePath = directory.isEmpty ? filename : "\(directory)/\(filename)"

            guard !shouldIgnore(relativePath, ignores) else { continue }

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
                let fileURL = diskURL/path/entry.name
                try FileManager.default.mkdir(fileURL)
                try blob.content.write(to: fileURL)
            }
        }
    }
}

extension Repo {

    // TODO: Review generated code
    // Build a tree from a flat dictionary of file references
    private func buildTreeFromFiles(_ files: [String: File]) async throws -> String {
        var rootEntries: [Tree.Entry] = []
        var subTrees: [String: [Tree.Entry]] = [:]

        // Group files by directory
        for (path, file) in files {
            let components = path.split(separator: "/").map(String.init)

            if components.count == 1 {
                // File in root directory
                rootEntries.append(.init(
                    mode: file.mode,
                    name: components[0],
                    hash: file.hash ?? ""
                ))
            } else {
                // File in subdirectory
                let dirPath = components.dropLast().joined(separator: "/")
                let fileName = components.last!

                subTrees[dirPath, default: []].append(.init(
                    mode: file.mode,
                    name: fileName,
                    hash: file.hash ?? ""
                ))
            }
        }

        // Build subtrees recursively
        var processedDirs: [String: String] = [:] // path -> tree hash

        // Sort directories by depth (deepest first)
        let sortedDirs = subTrees.keys.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }

        for dirPath in sortedDirs {
            let entries = subTrees[dirPath]!
            var treeEntries = entries

            // Add any subdirectories
            for (subDirPath, subDirHash) in processedDirs {
                if let subDirName = getImmediateSubdirectory(of: dirPath, fullPath: subDirPath) {
                    treeEntries.append(.init(
                        mode: .directory,
                        name: subDirName,
                        hash: subDirHash
                    ))
                }
            }

            let tree = Tree(entries: treeEntries.sorted { $0.name < $1.name })
            let treeHash = try await objects.store(tree, privateKey: privateKey)
            processedDirs[dirPath] = treeHash
        }

        // Add subdirectories to root
        for (dirPath, dirHash) in processedDirs {
            if !dirPath.contains("/") {
                rootEntries.append(.init(
                    mode: .directory,
                    name: dirPath,
                    hash: dirHash
                ))
            }
        }

        let rootTree = Tree(entries: rootEntries.sorted { $0.name < $1.name })
        return try await objects.store(rootTree, privateKey: privateKey)
    }

    // TODO: Review generated code
    private func getImmediateSubdirectory(of parent: String, fullPath: String) -> String? {
        guard fullPath.hasPrefix(parent + "/") else { return nil }
        let suffix = fullPath.dropFirst(parent.count + 1)
        let components = suffix.split(separator: "/")
        return components.count == 1 ? String(components[0]) : nil
    }

    // TODO: Review generated code
    // Update working directory to match a specific commit
    private func updateWorkingDirectory(to commitHash: String) async throws {
        let ignores = await retrieveIgnores() ?? [".DS_Store", ".wild"]

        // Clear current working directory (except .wild)
        let contents = try FileManager.default.contentsOfDirectory(at: diskURL, includingPropertiesForKeys: nil)
        for item in contents where !ignores.contains(item.lastPathComponent) {
            try FileManager.default.removeItem(at: item)
        }

        // Build new working directory
        let commit = try await objects.retrieve(commitHash, as: Commit.self)
        try await buildWorkingDirectoryRecursively(commit.tree)
    }
}
