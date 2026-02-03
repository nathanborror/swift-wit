import Foundation
import OSLog
import CryptoKit
import MIME

private let logger = Logger(subsystem: "Repo", category: "Wit")

public actor Repo {
    public static let defaultPath = ".wild"
    public static let defaultConfigPath = "\(defaultPath)/config"
    public static let defaultSecretsPath = "\(defaultPath)/secrets"
    public static let defaultObjectsPath = "\(defaultPath)/objects"
    public static let defaultHeadPath = "\(defaultPath)/HEAD"
    public static let defaultLogsPath = "\(defaultPath)/logs"

    public enum Error: Swift.Error {
        case missingHEAD
        case missingCommonAncestor
        case missingHash
        case missingRemote
        case missingPrivateKey
        case missingData
        case missingExtension
        case unknown(String)
    }

    public enum Ref: Sendable {
        case head
        case commit(String)
    }

    let localURL: URL
    let local: any Remote
    let objects: Objects
    let privateKey: Remote.PrivateKey?
    let ignores: [String]

    public init(baseURL: URL, folder: String, objectsPath: String? = nil, privateKey: Remote.PrivateKey? = nil, ignores: [String] = [".DS_Store"]) {
        self.localURL = baseURL.appending(path: folder)
        self.privateKey = privateKey
        self.local = RemoteDisk(baseURL: localURL)
        self.objects = Objects(
            remote: local,
            objectsPath: objectsPath ?? Self.defaultObjectsPath
        )
        self.ignores = ["^.wild"] + ignores // Always ignore `.wild`
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

    public func blob(hash: String, remote: Remote) async throws -> Data {
        try await retrieveBlob(hash, remote: remote)
    }

    public func binary(hash: String, remote: Remote) async throws -> Data {
        try await retrieveBinary(hash, remote: remote)
    }

    // MARK: Working with files

    /// Reads data from the path in the working directory.
    public func read(_ path: String) async throws -> Data {
        try await local.get(path: path)
    }

    /// Writes string to the path in the working directory.
    public func write(_ string: String?, path: String) async throws {
        guard let string, let data = string.data(using: .utf8) else { return }
        try await write(data, path: path)
    }

    /// Writes data to the path in the  working directory.
    public func write(_ data: Data, path: String, directoryHint: URL.DirectoryHint = .notDirectory) async throws {
        try await local.put(path: path, data: data, directoryHint: directoryHint, privateKey: privateKey)
    }

    public func writeBinary(_ data: Data, path: FilePath, remote: Remote?) async throws {
        guard let ext = path.ext else {
            throw Error.missingExtension
        }
        if let remote {
            let remoteObjects = Objects(remote: remote, objectsPath: Self.defaultObjectsPath)
            _ = try await remoteObjects.store(binary: data, ext: ext, privateKey: privateKey)
        }
        let hash = try await objects.store(binary: data, ext: ext, privateKey: privateKey)
        let aliasData = """
            Date: \(Date.now.toRFC1123)
            Content-Type: application/x-wild-alias
            Alias-Hash: \(hash)
            
            """.data(using: .utf8)!
        try await local.put(path: "\(path).alias", data: aliasData, directoryHint: .notDirectory, privateKey: privateKey)
    }

    /// Deletes file from working directory.
    public func delete(_ path: String) async throws {
        try await local.delete(path: path, privateKey: privateKey)
    }

    public func deleteBinary(_ hash: String, remote: Remote?) async throws {
        if let remote {
            let remoteObjects = Objects(remote: remote, objectsPath: Self.defaultObjectsPath)
            _ = try await remoteObjects.deleteBinary(hash: hash, privateKey: privateKey)
        }
        try await objects.deleteBinary(hash: hash, privateKey: privateKey)
    }

    public func move(_ path: String, to toPath: String) async throws {
        try await local.move(path: path, to: toPath)
    }

    public func localURL(_ path: String) -> URL {
        localURL.appending(path: path)
    }

    public func localURL(hash: String, kind: Objects.Key.Kind) async -> URL {
        let path = await objects.objectPath(.init(hash: hash, kind: kind))
        return localURL.appending(path: path)
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

    /// Clone a repository into a new directory. If bare is true then a working directory will not be created.
    public func clone(_ remote: Remote, bare: Bool = false, optimistic: Bool = false) async throws {
        try await initialize()

        let remoteObjects = Objects(remote: remote, objectsPath: Self.defaultObjectsPath)
        guard let remoteHead = await readHEAD(remote: remote) else {
            print("Remote HEAD missing")
            return
        }
        try await writeHEAD(hash: remoteHead, remote: local)

        // Copy necessary files
        for path in [
            Self.defaultConfigPath,
            Self.defaultSecretsPath,
            Self.defaultLogsPath,
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
            // Optimistic clones skip downloading of blob data
            if !optimistic && key.kind == .blob {
                continue
            }
            let path = await objects.objectPath(key)
            let data = try await remote.get(path: path)
            try await write(data, path: path)
        }

        if bare { return }

        // Create working directory
        let commit = try await objects.retrieve(commit: remoteHead)
        try await buildWorkingDirectoryRecursively(commit.tree, remote: remote)

        let remoteURLString = await remote.baseURL.absoluteString
        await postStatusNotification("Cloned '\(remoteURLString)'")
    }

    /// Create an empty repository.
    public func initialize() async throws {
        let manager = FileManager.default

        try manager.touch(localURL/Self.defaultConfigPath)
        try manager.touch(localURL/Self.defaultSecretsPath)
        try manager.touch(localURL/Self.defaultHeadPath)
        try manager.touch(localURL/Self.defaultLogsPath)

        try manager.mkdir(localURL/Self.defaultObjectsPath)
        try manager.mkdir(localURL/Self.defaultPath/"remotes"/"origin")

        try await write("""
            Date: \(Date.now.toRFC1123)
            Content-Type: text/csv; charset=utf8; header=present; profile=logs 
            
            timestamp,hash,parent,message
            
            """, path: Self.defaultLogsPath)

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
        guard let data = try? await read(Self.defaultLogsPath) else { return [] }
        let message = try MIMEDecoder().decode(data)
        guard let part = message.parts.first else {
            throw Error.unknown("missing log part")
        }
        return try LogDecoder().decode(part.body)
    }

    // MARK: Grow and tweak common history

    /// Record changes to the repository.
    @discardableResult
    public func commit(_ message: String) async throws -> String {
        let head = await readHEAD(remote: local)
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
        try await writeHEAD(hash: commitHash, remote: local)
        try await log(commit: commit, hash: commitHash)

        await postStatusNotification("Committed '\(message)'")
        return commitHash
    }

    /// Reapply commits on top of HEAD.
    @discardableResult
    public func rebase(_ remote: Remote) async throws -> String {
        try await fetch(remote)

        let head = await readHEAD(remote: local)
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
            try await checkout(remoteHead, remote: remote)
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
        try await writeHEAD(hash: finalHead, remote: local)

        // Checkout and update final HEAD
        try await checkout(finalHead, remote: remote)
        await postStatusNotification("Rebased \(localChain.count) commits on top of remote")
        return finalHead
    }

    /// Checkouts a commit by changing the HEAD to the given commit and rebuilding the working directory.
    public func checkout(_ commitHash: String, remote: Remote) async throws {
        try await updateWorkingDirectory(to: commitHash, remote: remote)
        try await writeHEAD(hash: commitHash, remote: local)
        await postStatusNotification("Checked out commit (\(commitHash.prefix(7)))")
    }

    // MARK: Workflows

    /// Update remote along with associated objects.
    public func push(_ remote: Remote) async throws {
        guard let head = await readHEAD(remote: local) else {
            await postStatusNotification("Nothing to push — missing local HEAD")
            return
        }

        // Get remote HEAD and all reachable hashes from local storage, compare with reachable hashes from remote
        // storage and determine what needs to be pushed.

        let remoteObjects = Objects(remote: remote, objectsPath: Self.defaultObjectsPath)
        let remoteHead = await readHEAD(remote: remote) ?? ""

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
            case .binary:
                guard let ext = FilePath(key.hash).ext else { continue }
                let binary = try await objects.retrieve(binary: key.hash)
                let _ = try await remoteObjects.store(binary: binary, ext: ext, privateKey: privateKey)
            }
        }

        // Upload current HEAD, logs and config to remote
        for path in [
            Self.defaultConfigPath,
            Self.defaultSecretsPath,
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
        let remoteHead = await readHEAD(remote: remote) ?? ""
        try await write(remoteHead, path: "\(Self.defaultPath)/remotes/origin/HEAD")

        // Local head
        let head = await readHEAD(remote: local)

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

    // MARK: HEAD

    public func readHEAD(remote: Remote) async -> String? {
        guard let data = try? await remote.get(path: Self.defaultHeadPath) else {
            return nil
        }
        guard let message = try? MIMEDecoder().decode(data) else {
            return nil
        }
        guard let part = message.parts.first else {
            return nil
        }
        let hash = part.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    private func writeHEAD(hash: String, remote: Remote) async throws {
        try await remote.put(
            path: Self.defaultHeadPath,
            data: """
                Date: \(Date.now.toRFC1123)
                Content-Type: text/plain 
                
                \(hash.trimmingCharacters(in: .whitespacesAndNewlines))
                """.data(using: .utf8),
            directoryHint: .notDirectory,
            privateKey: privateKey
        )
    }
}

// MARK: - Private

extension Repo {

    func retrieveHash(ref: Ref) async throws -> String {
        switch ref {
        case .head:
            guard let hash = await readHEAD(remote: local) else {
                throw Error.missingHash
            }
            return hash
        case .commit(let hash):
            return hash
        }
    }

    /// Returns a dictionary of file references for files in the working directory keyed with their path.
    func retrieveCurrentFileReferences(at path: String = "") async throws -> [String: File] {
        let files = try await local.list(path: path)
        var out: [String: File] = [:]
        for relativePath in files {
            if shouldIgnore(path: relativePath) {
                continue
            }
            let url = localURL.appending(path: relativePath)
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

        var entries: [Tree.Entry] = []
        let directoryURL = directory.isEmpty ? localURL : (localURL/directory)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
        )

        for item in contents {
            let filename = item.lastPathComponent
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let isRegularFile = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            let relativePath: FilePath = directory.isEmpty ? filename : "\(directory)/\(filename)"

            guard !shouldIgnore(path: relativePath) else {
                continue
            }

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
    func buildWorkingDirectoryRecursively(_ treeHash: String, path: String = "", remote: Remote) async throws {
        let tree = try await objects.retrieve(tree: treeHash)
        for entry in tree.entries {
            switch entry.mode {
            case .directory:
                let path = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
                try await buildWorkingDirectoryRecursively(entry.hash, path: path, remote: remote)
            case .normal:
                let data = try await retrieveBlob(entry.hash, remote: remote)
                let fileURL = localURL/path/entry.name
                try FileManager.default.mkdir(fileURL)
                try data.write(to: fileURL)
            }
        }
    }

    func retrieveBlob(_ hash: String, remote: Remote) async throws -> Data {
        let key = Objects.Key(hash: hash, kind: .blob)
        if try await objects.exists(key: key) {
            return try await objects.retrieve(blob: hash)
        } else {
            let path = await objects.objectPath(key)
            let data = try await remote.get(path: path)
            try await write(data, path: path)
            return data
        }
    }

    func retrieveBinary(_ hash: String, remote: Remote) async throws -> Data {
        let key = Objects.Key(hash: hash, kind: .binary)
        if try await objects.exists(key: key) {
            return try await objects.retrieve(binary: hash)
        } else {
            let path = await objects.objectPath(key)
            let data = try await remote.get(path: path)
            try await write(data, path: path)
            return data
        }
    }
}

extension Repo {

    private func shouldIgnore(path: FilePath) -> Bool {
        for ignore in ignores {
            let re = try! Regex(ignore)
            if path.firstMatch(of: re) != nil {
                return true
            }
        }
        return false
    }

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
    private func updateWorkingDirectory(to commitHash: String, remote: Remote) async throws {

        // Clear current working directory (except .wild)
        for item in try FileManager.default.contentsOfDirectory(at: localURL, includingPropertiesForKeys: nil) {
            let relativePath = item.standardizedFileURL.path.replacingOccurrences(of: localURL.path + "/", with: "")
            if relativePath != Self.defaultPath {
                try FileManager.default.removeItem(at: item)
            }
        }

        // Build new working directory
        let commit = try await objects.retrieve(commit: commitHash)
        try await buildWorkingDirectoryRecursively(commit.tree, remote: remote)
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

// MARK: - Encyrption

extension Repo {

    public func dataDecrypt(_ data: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
        guard !data.isEmpty else {
            throw Error.missingData
        }
        var cursor = 0
        let hdrLenBE = data[cursor..<cursor+4]; cursor += 4
        let hdrLen = Int(hdrLenBE.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        let headerData = data[cursor..<cursor+hdrLen]; cursor += hdrLen
        let header = try JSONDecoder().decode(EncryptionHeader.self, from: headerData)

        precondition(header.magic == "WILDCRYPT" && header.version == 1)

        let key = issueSymmetricKey(privateKey, salt: header.salt)
        let nonce = try ChaChaPoly.Nonce(data: header.nonce)

        // Remaining = ciphertext||tag (16-byte tag)
        let ct = data[cursor..<(data.count - 16)]
        let tag = data[(data.count - 16)..<data.count]

        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(box, using: key)
    }

    public func dataEncrypt(_ data: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
        guard !data.isEmpty else {
            throw Error.missingData
        }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key  = issueSymmetricKey(privateKey, salt: salt)

        let nonce = try ChaChaPoly.Nonce(data: Data((0..<12).map { _ in UInt8.random(in: 0...255) }))
        let sealed = try ChaChaPoly.seal(data, using: key, nonce: nonce)

        let header = EncryptionHeader(magic: "WILDCRYPT", version: 1, salt: salt, nonce: Data(nonce))
        let headerData = try JSONEncoder().encode(header)

        // Write [varint headerLen][header][ciphertext||tag]
        var secrets = Data()
        var headerLen = UInt32(headerData.count).bigEndian
        withUnsafeBytes(of: &headerLen) { secrets.append(contentsOf: $0) }
        secrets.append(headerData)
        secrets.append(sealed.ciphertext)
        secrets.append(sealed.tag)
        return secrets
    }

    private func issueSymmetricKey(_ signingKey: Curve25519.Signing.PrivateKey, salt: Data) -> SymmetricKey {
        let raw = signingKey.rawRepresentation
        let seed = raw.prefix(32)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: .init(data: seed),
            salt: salt,
            info: Data("Wild Encryption v1".utf8),
            outputByteCount: 32
        )
    }

    private func randomString(length: Int = 16) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in letters.randomElement()! })
    }

    struct EncryptionHeader: Codable {
        let magic: String
        let version: UInt8
        let salt: Data
        let nonce: Data
    }
}
