import Foundation
import CryptoKit

public final class Repo {
    static let defaultPath = ".wild"
    static let defaultConfigPath = "\(defaultPath)/config"
    static let defaultObjectsPath = "\(defaultPath)/objects"
    static let defaultHeadPath = "\(defaultPath)/HEAD"
    static let defaultLogsPath = "\(defaultPath)/logs"

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
    public func clone(_ url: URL) async throws {
        try await initialize()

        let remote = RemoteHTTP(baseURL: url)
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
            let hashPath = objects.hashPath(hash)
            let path = ".wild/objects/\(hashPath)"
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
    public func log() async throws -> [String] {
        let logs = await retrieveLogs()
        return logs.split(separator: "\n").map(String.init)
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
        try await writeLog(commitHash, commit: commit)

        return commitHash
    }

    /// Reapply commits on top of HEAD.
    public func rebase(_ remote: Remote) async throws {
        try await fetch(remote)

        let head = await retrieveHEAD()
        let remoteHeadData = try await read(".wild/remotes/origin/HEAD")
        let remoteHead = String(data: remoteHeadData, encoding: .utf8) ?? ""

        guard !head.isEmpty, !remoteHead.isEmpty else {
            print("Either local HEAD or remote HEAD is missing")
            return
        }
        if head == remoteHead {
            print("Nothing to rebase; already up-to-date")
            return
        }

        // 3. Find common ancestor
        let ancestor = try await findCommonAncestor(localHead: head, remoteHead: remoteHead)
        guard let base = ancestor else {
            print("No common ancestor found; refusing to rebase")
            return
        }

        // 4. Collect local-only commits (from localHead back to base, reversed)
        let localChain = try await ancestryPath(from: head, stopBefore: base)
        if localChain.isEmpty {
            print("Nothing to rebase; local has no unique commits")
            return
        }

        // 5. Replay (recommit) on top of remoteHead
        var newParent = remoteHead
        var newCommits: [String] = []
        for hash in localChain.reversed() {
            let commit = try await objects.retrieve(hash, as: Commit.self)
            // Commit may refer to an old tree; instead, you might want to re-stage files for each commit, or at minimum use their tree as-is.
            // If you want to re-apply diffs/patches (true rebase), that's more complex; for now we copy as if the tree is the working tree.
            let rebasedCommit = Commit(
                tree: commit.tree,
                parent: newParent,
                author: commit.author,
                message: commit.message,
                timestamp: commit.timestamp
            )
            let newHash = try await objects.store(rebasedCommit, privateKey: privateKey)
            newParent = newHash
            newCommits.append(newHash)

            // TODO: Write commit to log
        }
        guard let finalHead = newCommits.last, let finalHeadData = finalHead.data(using: .utf8) else { return }

        // 6. Update local HEAD & manifest & logs
        try await write(finalHeadData, path: Self.defaultHeadPath)

        // Log new commits
        for newHash in newCommits {
            let commit = try await objects.retrieve(newHash, as: Commit.self)
            try await writeLog(newHash, commit: commit)
        }

        print("Rebased \(localChain.count) commits on top of remote, new HEAD: \(finalHead)")
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
        let currentLogs = await retrieveLogs()
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
            let hashPath = objects.hashPath(hash)
            let path = ".wild/objects/\(hashPath)"
            let data = try await remote.get(path: path)
            try await write(data, path: path)
        }

        // Download remote logs
        if let remoteLogs = try? await remote.get(path: Self.defaultLogsPath) {
            try await write(remoteLogs, path: ".wild/remotes/origin/logs")
        }
    }

    // MARK: Configuration

    public func config() async throws -> [String: String] {
        let configData = try await disk.get(path: Self.defaultConfigPath)
        let config = String(data: configData, encoding: .utf8) ?? ""
        return readINI(config)
    }

    public func config(_ values: [String: String], remote: Remote? = nil) async throws {
        var config = try await config()
        config.merge(values) { _, new in new }

        let newConfig = writeINI(config)
        let newConfigData = newConfig.data(using: .utf8)!
        try await disk.put(path: Self.defaultConfigPath, data: newConfigData, mimetype: nil, privateKey: nil)

        if let remote {
            try await remote.put(path: Self.defaultConfigPath, data: newConfigData, mimetype: nil, privateKey: privateKey)
        }
    }
}

// MARK: - Private

extension Repo {

    func retrieveHEAD() async -> String {
        guard let data = try? await read(Self.defaultHeadPath) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func retrieveLogs() async -> String {
        guard let data = try? await read(Self.defaultLogsPath) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func retrieveCurrentFileReferences(at path: String = "") async throws -> [String: File] {
        let files = try await disk.list(path: path)
        var out: [String: File] = [:]
        for (relativePath, url) in files {
            guard !shouldIgnore(path: relativePath) else { continue }
            if let hash = try? objects.hash(for: url) {
                out[relativePath] = .init(path: relativePath, hash: hash, mode: .normal)
            }
        }
        return out
    }

    func shouldIgnore(path: String) -> Bool {
        let ignore = [".DS_Store", ".wild"]
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
        return try await objects.store(tree, privateKey: privateKey)
    }

    func writeLog(_ hash: String, commit: Commit) async throws {
        let timestamp = dateFormatter(commit.timestamp)
        let parts = [
            timestamp,
            "COMMIT",
            hash,
            commit.parent.isEmpty ? nil : commit.parent,
        ].compactMap { $0 }

        let message = "\(parts.joined(separator: " ")) :\(commit.message)\n"
        let messageData = message.data(using: .utf8)

        if let fileHandle = FileHandle(forUpdatingAtPath: (url/Self.defaultLogsPath).path) {
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
            try await write(messageData, path: ".wild/logs")
        }
    }

    func dateFormatter(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    // TODO: Review generated code
    func readINI(_ input: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentSection = ""

        let sectionRegex = try! NSRegularExpression(pattern: #"^\[(.+?)(?:\s+"(.+?)")?\]$"#)

        for line in input.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
                continue // skip comments and empty lines
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if let match = sectionRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                    let section = (trimmed as NSString).substring(with: match.range(at: 1))
                    if match.range(at: 2).location != NSNotFound {
                        let subsection = (trimmed as NSString).substring(with: match.range(at: 2))
                        currentSection = "\(section).\(subsection)"
                    } else {
                        currentSection = section
                    }
                }
            } else if let equalIndex = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<equalIndex].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: equalIndex)...].trimmingCharacters(in: .whitespaces)
                let dictKey = currentSection.isEmpty ? key : "\(currentSection).\(key)"
                result[dictKey] = value
            }
        }
        return result
    }

    // TODO: Review generated code
    func writeINI(_ input: [String: String]) -> String {
        // Group keys by section
        var sections: [String: [String: String]] = [:]
        for (fullKey, value) in input {
            let parts = fullKey.split(separator: ".")
            guard parts.count >= 2 else { continue }
            let section = parts.count == 3
                ? "\(parts[0]) \"\(parts[1])\""
                : String(parts[0])
            let key = parts.count == 3
                ? String(parts[2])
                : String(parts[1])
            sections[section, default: [:]][key] = value
        }
        // Write sections
        var lines: [String] = []
        for section in sections.keys.sorted() {
            lines.append("[\(section)]")
            for (key, value) in sections[section]!.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(key) = \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
