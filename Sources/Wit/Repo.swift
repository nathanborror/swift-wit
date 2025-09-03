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
        case missingRemote
    }

    public enum Ref: Sendable {
        case head
        case commit(String)
    }

    let localURL: URL
    let local: any Remote
    let objects: Objects
    let privateKey: Remote.PrivateKey?

    public init(path: String, objectsPath: String? = nil, privateKey: Remote.PrivateKey? = nil) {
        self.localURL = URL.documentsDirectory.appending(path: path)
        self.privateKey = privateKey
        self.local = RemoteDisk(baseURL: localURL)
        self.objects = Objects(
            remote: local,
            objectsPath: objectsPath ?? Self.defaultObjectsPath
        )
    }

    // MARK: Convenience

    public func commit(ref: Ref = .head) async throws -> Commit {
        let hash = try await retrieveHash(ref: ref)
        let commit = try await objects.retrieve(commit: hash)
        return commit
    }

    public func tree(hash: String) async throws -> Tree {
        try await objects.retrieve(tree: hash)
    }

    public func blob(hash: String) async throws -> Data {
        try await objects.retrieve(blob: hash)
    }

    // MARK: Working with files

    public func read(_ path: String) async throws -> Data {
        try await local.get(path: path)
    }

    public func write(_ string: String?, path: String) async throws {
        guard let string, let data = string.data(using: .utf8) else { return }
        try await write(data, path: path)
    }

    public func write(_ data: Data, path: String, directoryHint: URL.DirectoryHint = .notDirectory) async throws {
        try await local.put(path: path, data: data, directoryHint: directoryHint, privateKey: privateKey)
    }

    public func move(_ path: String, to toPath: String) async throws {
        try await local.move(path: path, to: toPath)
    }

    public func delete(_ path: String) async throws {
        try await local.delete(path: path, privateKey: privateKey)
    }

    public func localURL(_ path: String) -> URL {
        localURL.appending(path: path)
    }

    public func localExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: localURL(path).path)
    }

    public func localExistsAsDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let _ = FileManager.default.fileExists(atPath: localURL(path).path, isDirectory: &isDir)
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
        try await writeHEAD(remoteHead)

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
        let remoteKeys = try await remoteObjects.retrieveCommitKeys(remoteHead)
        for key in remoteKeys {
            guard try await !objects.exists(key: key) else {
                continue
            }
            let path = await objects.objectPath(key)
            let data = try await remote.get(path: path)
            try await write(data, path: path)
        }

        // Copy use picture
        let config = try await configRead(path: Self.defaultConfigPath)
        if let filename = config["user.picture"], let data = try? await remote.get(path: "\(Self.defaultPath)/\(filename)") {
            try await write(data, path: "\(Self.defaultPath)/\(filename)")
        }

        if bare { return }

        // Create working directory
        let commit = try await objects.retrieve(commit: remoteHead)
        try await buildWorkingDirectoryRecursively(commit.tree)

        let remoteURLString = await remote.baseURL.absoluteString
        await postStatusNotification("Cloned '\(remoteURLString)'")
    }

    /// Create an empty repository.
    public func initialize(_ remote: Remote? = nil) async throws {
        let manager = FileManager.default

        try manager.touch(localURL/Self.defaultConfigPath)
        try manager.touch(localURL/Self.defaultHeadPath)
        try manager.touch(localURL/Self.defaultLogsPath)

        try manager.mkdir(localURL/Self.defaultObjectsPath)
        try manager.mkdir(localURL/Self.defaultPath/"remotes"/"origin")

        // Determine remote (nil is okay)
        let defaultRemote = try? await configRemoteDefault()
        let remote = remote ?? defaultRemote

        // Set current version
        try await configMerge(
            path: Self.defaultConfigPath,
            values: ["core": .dictionary(["version": "0.1"])],
            remote: remote
        )

        await postStatusNotification("Initialized repository")
    }

    // MARK: Examine history and state

    /// Show the working tree status.
    public func status(_ ref: Ref = .head) async throws -> [File] {
        let commitHash = try? await retrieveHash(ref: ref)

        // Gather file references within the commit
        let fileReferences: [String: File]
        if let commitHash {
            let commit = try await objects.retrieve(commit: commitHash)
            let tree = try await objects.retrieve(tree: commit.tree)
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

    /// Show commit logs.
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
        let head = await readHEAD()
        var files = try await status()

        // Store blobs, generate hashes and update the file references before building new tree structure
        for (index, file) in files.enumerated() {
            guard file.state != .deleted else { continue }
            let data = try await local.get(path: file.path)
            let hash = try await objects.store(blob: data, privateKey: privateKey)
            files[index] = file.apply(hash: hash)
        }

        let parentCommit: Commit?
        if let head {
            parentCommit = try await objects.retrieve(commit: head)
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
        let commitHash = try await objects.store(commit: commit, privateKey: privateKey)

        // Update HEAD, log commit
        try await writeHEAD(commitHash)
        try await log(commit: commit, hash: commitHash)

        await postStatusNotification("Committed '\(message)'")
        return commitHash
    }

    /// Reapply commits on top of HEAD.
    @discardableResult
    public func rebase(_ remote: Remote? = nil) async throws -> String {
        let defaultRemote = try? await configRemoteDefault()
        guard let remote = remote ?? defaultRemote else {
            throw Error.missingRemote
        }

        try await fetch(remote)

        let head = await readHEAD()
        let remoteHeadData = try await read("\(Self.defaultPath)/remotes/origin/HEAD")
        let remoteHead = String(data: remoteHeadData, encoding: .utf8)

        guard let head, let remoteHead else {
            throw Error.missingHEAD
        }
        if head == remoteHead {
            await postStatusNotification("Nothing to rebase — already up-to-date")
            return head
        }

        // Determine common ancestor
        guard let ancestor = try await findCommonAncestor(localHead: head, remoteHead: remoteHead) else {
            throw Error.missingCommonAncestor
        }

        // Determine local-only commits (from localHead back to common ancestor, reversed)
        let localChain = try await ancestryPath(from: head, stopBefore: ancestor)

        if localChain.isEmpty {
            await postStatusNotification("Nothing to rebase — no unique commits")

            // Update logs
            let remoteLogs = try await read("\(Self.defaultPath)/remotes/origin/logs")
            try await write(remoteLogs, path: Self.defaultLogsPath)

            // Checkout and make the remote head the current HEAD
            try await checkout(remoteHead)
            return remoteHead
        }

        // Get the file state at the remote HEAD
        let remoteCommit = try await objects.retrieve(commit: remoteHead)
        let remoteTree = try await objects.retrieve(tree: remoteCommit.tree)
        var currentFiles = try await objects.retrieveFileReferencesRecursive(remoteTree)

        // Replay (recommit) on top of remoteHead
        var newParent = remoteHead
        var rebasedCommits: [String] = []

        for hash in localChain.reversed() {
            let commit = try await objects.retrieve(commit: hash)

            // Get the changes introduced by this commit
            let commitTree = try await objects.retrieve(tree: commit.tree)
            let commitFiles = try await objects.retrieveFileReferencesRecursive(commitTree)

            let parentFiles: [String: File]
            if let parent = commit.parent {
                let parentCommit = try await objects.retrieve(commit: parent)
                let parentTree = try await objects.retrieve(tree: parentCommit.tree)
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
            let rebasedCommitHash = try await objects.store(commit: rebasedCommit, privateKey: privateKey)
            newParent = rebasedCommitHash
            rebasedCommits.append(rebasedCommitHash)

            try await log(commit: rebasedCommit, hash: rebasedCommitHash)
        }

        // Update local HEAD
        guard let finalHead = rebasedCommits.last else {
            throw Error.missingHEAD
        }
        try await writeHEAD(finalHead)

        // Checkout and update final HEAD
        try await checkout(finalHead)
        await postStatusNotification("Rebased \(localChain.count) commits on top of remote")
        return finalHead
    }

    /// Checkouts a commit by changing the HEAD to the given commit and rebuilding the working directory.
    public func checkout(_ commitHash: String) async throws {
        try await updateWorkingDirectory(to: commitHash)
        try await writeHEAD(commitHash)
        await postStatusNotification("Checked out commit (\(commitHash.prefix(7)))")
    }

    // MARK: Workflows

    /// Update remote along with associated objects.
    public func push(_ remote: Remote? = nil) async throws {
        let defaultRemote = try? await configRemoteDefault()
        guard let remote = remote ?? defaultRemote else {
            throw Error.missingRemote
        }

        guard let head = await readHEAD() else {
            await postStatusNotification("Nothing to push — missing local HEAD")
            return
        }

        // Get remote HEAD and all reachable hashes from local storage, compare with reachable hashes from remote
        // storage and determine what needs to be pushed.

        let remoteObjects = Objects(remote: remote, objectsPath: Self.defaultObjectsPath)
        let remoteHeadData = try? await remote.get(path: Self.defaultHeadPath)
        let remoteHead = String(data: remoteHeadData ?? Data(), encoding: .utf8) ?? ""

        let remoteReachable = (!remoteHead.isEmpty) ? try await remoteObjects.retrieveCommitKeys(remoteHead) : []
        let localReachable = try await objects.retrieveCommitKeys(head)
        let keysToPush = localReachable.subtracting(remoteReachable)

        if keysToPush.isEmpty {
            await postStatusNotification("Nothing to push — remote up-to-date")
            return
        }

        for key in keysToPush {
            switch key.kind {
            case .commit:
                let commit = try await objects.retrieve(commit: key.hash)
                let _ = try await remoteObjects.store(commit: commit, privateKey: privateKey)
            case .tree:
                let tree = try await objects.retrieve(tree: key.hash)
                let _ = try await remoteObjects.store(tree: tree, privateKey: privateKey)
            case .blob:
                let blob = try await objects.retrieve(blob: key.hash)
                let _ = try await remoteObjects.store(blob: blob, privateKey: privateKey)
            }

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
        let remoteURLString = await remote.baseURL.absoluteString
        await postStatusNotification("Pushed \(keysToPush.count) objects to '\(remoteURLString)'")
    }

    /// Fetch from and integrate with another repository.
    public func pull(_ remote: Remote? = nil) async throws {
        fatalError("not implemented")
    }

    /// Download objects from another repository.
    public func fetch(_ remote: Remote? = nil) async throws {
        let defaultRemote = try? await configRemoteDefault()
        guard let remote = remote ?? defaultRemote else {
            throw Error.missingRemote
        }

        // Copy remote config
        if let remoteConfig = try? await remote.get(path: Self.defaultConfigPath) {
            try await write(remoteConfig, path: Self.defaultConfigPath)
        }

        // Download remote head
        let remoteHeadData = try await remote.get(path: Self.defaultHeadPath)
        let remoteHead = String(data: remoteHeadData, encoding: .utf8) ?? ""
        try await write(remoteHeadData, path: "\(Self.defaultPath)/remotes/origin/HEAD")

        // Local head
        let head = await readHEAD()

        // Compare heads
        guard !remoteHead.isEmpty, head != remoteHead else { return }

        // Download remote objects
        let remoteObjects = Objects(remote: remote, objectsPath: Self.defaultObjectsPath)
        let remoteKeys = try await remoteObjects.retrieveCommitKeys(remoteHead)
        for key in remoteKeys {
            guard try await !objects.exists(key: key) else {
                continue
            }
            let path = await objects.objectPath(key)
            let data = try await remote.get(path: path)
            try await write(data, path: path)
        }

        // Download remote logs
        if let remoteLogs = try? await remote.get(path: Self.defaultLogsPath) {
            try await write(remoteLogs, path: "\(Self.defaultPath)/remotes/origin/logs")
        }
    }

    // MARK: Configuration

    /// Returns the config file as a string dictionary.
    public func configRead(path: String) async throws -> Config {
        let data = try await local.get(path: path)
        return ConfigDecoder().decode(data)
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
        try await local.put(path: path, data: newConfigData, directoryHint: .notDirectory, privateKey: nil)

        let defaultRemote = try? await configRemoteDefault()
        if let remote = remote ?? defaultRemote {
            try await remote.put(path: path, data: newConfigData, directoryHint: .notDirectory, privateKey: privateKey)
        }
    }

    /// Returns the default Remote if the `core.remote` property is set. This remote will get used when a remote parameter is nil.
    public func configRemoteDefault() async throws -> Remote? {
        let config = try await configRead(path: Self.defaultConfigPath)
        guard let name = config["core.remote"] else { return nil }
        guard case .dictionary(let values) = config[section: "remote:\(name)"] else { return nil }
        switch values["kind"] {
        case "wild":
            guard
                let host = values["host"],
                let baseURL = URL(string: host)
            else { return nil }
            return RemoteHTTP(baseURL: baseURL)
        case "s3":
            guard
                let bucket = values["bucket"],
                let path = values["path"],
                let region = values["region"],
                let accessKey = values["accessKey"],
                let secretKey = values["secretKey"]
            else { return nil }
            return RemoteS3(bucket: bucket, path: path, region: region, accessKey: accessKey, secretKey: secretKey)
        default:
            return nil
        }
    }

    // MARK: HEAD

    public func readHEAD() async -> String? {
        guard let data = try? await read(Self.defaultHeadPath) else {
            return nil
        }
        if let hash = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return hash.isEmpty ? nil : hash
        }
        return nil
    }

    private func writeHEAD(_ hash: String) async throws {
        try await write(hash.trimmingCharacters(in: .whitespacesAndNewlines), path: Self.defaultHeadPath)
    }
}

// MARK: - Private

extension Repo {

    func retrieveHash(ref: Ref) async throws -> String {
        switch ref {
        case .head:
            guard let hash = await readHEAD() else {
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
        let ignores = await retrieveIgnores() ?? [".DS_Store", Self.defaultPath]
        let files = try await local.list(path: path, ignores: ignores)
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
        try await log(path: Self.defaultLogsPath, append: line)
    }

    /// Appends line to given log file.
    func log(path: String, append line: String) async throws {
        guard let lineData = line.data(using: .utf8) else { return }
        let logsData = try await read(Self.defaultLogsPath)
        try await write(logsData+lineData, path: path)
    }

    // TODO: Review generated code
    func findCommonAncestor(localHead: String, remoteHead: String) async throws -> String? {
        // Collect all ancestors of remote
        var remoteAncestors = Set<String>()
        var stack: [String] = [remoteHead]
        while let hash = stack.popLast() {
            if hash.isEmpty || remoteAncestors.contains(hash) { continue }
            remoteAncestors.insert(hash)
            let commit = try? await objects.retrieve(commit: hash)
            if let parent = commit?.parent { stack.append(parent) }
        }
        // Walk local chain, return first common commit
        var current = localHead
        while !current.isEmpty {
            if remoteAncestors.contains(current) { return current }
            let commit = try? await objects.retrieve(commit: current)
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
            let commit = try? await objects.retrieve(commit: curr)
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
            return await objects.computeHash(data)
        }

        // Files to ignore
        let ignores = await retrieveIgnores() ?? [".DS_Store", Self.defaultPath]

        var entries: [Tree.Entry] = []
        let directoryURL = directory.isEmpty ? localURL : (localURL/directory)
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
        return try await objects.store(tree: tree, privateKey: privateKey)
    }

    /// Build a directory of files from the object store relative to the given tree hash. Recurse down the tree to build a complete directory structure.
    func buildWorkingDirectoryRecursively(_ treeHash: String, path: String = "") async throws {
        let tree = try await objects.retrieve(tree: treeHash)
        for entry in tree.entries {
            switch entry.mode {
            case .directory:
                let path = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
                try await buildWorkingDirectoryRecursively(entry.hash, path: path)
            case .normal, .executable, .symbolicLink:
                let data = try await objects.retrieve(blob: entry.hash)
                let fileURL = localURL/path/entry.name
                try FileManager.default.mkdir(fileURL)
                try data.write(to: fileURL)
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
            let treeHash = try await objects.store(tree: tree, privateKey: privateKey)
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
        return try await objects.store(tree: rootTree, privateKey: privateKey)
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
        let ignores = await retrieveIgnores() ?? [".DS_Store", Self.defaultPath]

        // Clear current working directory (except .wild)
        let contents = try FileManager.default.contentsOfDirectory(at: localURL, includingPropertiesForKeys: nil)
        for item in contents where !ignores.contains(item.lastPathComponent) {
            try FileManager.default.removeItem(at: item)
        }

        // Build new working directory
        let commit = try await objects.retrieve(commit: commitHash)
        try await buildWorkingDirectoryRecursively(commit.tree)
    }
}

// MARK: - Notifications

extension Repo {

    public static let statusNotification = Notification.Name("wit.repo.status")

    @MainActor
    private func postStatusNotification(_ message: String) {
        logger.info("\(message)")
        let userInfo: [String: String] = [
            "message": message,
        ]
        NotificationCenter.default.post(name: Self.statusNotification, object: nil, userInfo: userInfo)
    }
}
