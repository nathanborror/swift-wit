import Foundation
import CryptoKit

public final class Client {
    let baseURL: URL

    let witDir: URL
    let storage: ObjectStore
    let ignored: Set<String>

    public init(_ baseURL: URL, objectsURL: URL? = nil, ignore: Set<String> = []) throws {
        self.baseURL = baseURL

        self.witDir = baseURL.appending(path: ".wild")

        for item in ["config", "HEAD", "manifest", "logs"] {
            let url = witDir.appending(path: item)
            try FileManager.default.createFileIfNeeded(url)
        }
        self.storage = try ObjectStore(baseURL: witDir.appending(path: "objects"))
        self.ignored = ignore.union([".wild", ".DS_Store"])
    }

    /// The current HEAD commit hash.
    ///
    /// This property gets or sets the `HEAD` reference used by the repository. When accessed, it reads the commit hash stored in the `.wit/HEAD` file,
    /// trimming any whitespace or newlines. Setting this property updates the file to the new commit hash value.
    /// If no `HEAD` is present, the getter returns `nil`.
    public var head: String? {
        get {
            let out = try? String(contentsOf: witDir.appending(path: "HEAD"), encoding: .utf8)
            return out?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            try? newValue?.write(to: witDir.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        }
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
        let commitHash = commitHash ?? head ?? ""
        let commit = try storage.retrieve(commitHash, as: Commit.self)
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
    public func commit(message: String, author: String, timestamp: Date = .now, previousCommitHash: String = EmptyHash) throws -> String {
        let previousCommit = try? storage.retrieve(previousCommitHash, as: Commit.self)

        var files = try treeFilesChanged(previousCommit?.tree)

        for (index, file) in files.enumerated() {
            if file.kind != .deleted {
                let fileURL = baseURL.appending(path: file.path)
                let blob = try Blob(url: fileURL)
                let hash = try storage.store(blob)
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
        let commitHash = try storage.store(commit)

        // Update HEAD
        head = commitHash

        // Update Manifest
        try writeManifest(head!)

        // Append log
        log(commitHash, commit: commit)

        return head!
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
        let commitHash = commitHash ?? head ?? ""
        if commitHash.isEmpty {
            return []
        }
        let commit = try storage.retrieve(commitHash, as: Commit.self)
        let files = try treeFiles(commit.tree, path: "")
        return files.values.sorted { $0.path < $1.path }
    }

    public func fetch(remote: Remote) async throws {
        let remoteDirURL = remote.baseURL.appending(path: ".wild")
        let remoteObjectsURL = remoteDirURL.appending(path: "objects")
        let remoteHeadURL = remoteDirURL.appending(path: "HEAD")

        guard let remoteHead = try? String(contentsOf: remoteHeadURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !remoteHead.isEmpty else {
            print("Remote HEAD not found")
            return
        }
        let remoteObjectStore = try ObjectStore(baseURL: remoteObjectsURL)
        let commitsToFetch = try reachableHashes(from: remoteHead, using: remoteObjectStore)

        for hash in commitsToFetch {
            if try !storage.exists(hash: hash) {
                let srcURL = remoteObjectsURL.appendingPathComponent(hash)
                let dstURL = storage.baseURL.appendingPathComponent(hash)

                let (data, etag) = try await remote.get(url: srcURL, etag: nil)
                // Figure out what to store (e.g. Commit, Tree or Object)
            }
        }
    }

    public func push(remote: Remote, privateKey: Curve25519.Signing.PrivateKey) async throws {
        let remoteDirURL = remote.baseURL.appending(path: ".wild")
        let remoteObjectsURL = remoteDirURL.appending(path: "objects")
        let remoteHeadURL = remoteDirURL.appending(path: "HEAD")

        guard let head, !head.isEmpty else {
            print("Nothing to push: local HEAD not set")
            return
        }

        // Get remote HEAD and all reachable hashes from local storage, compare with reachable hashes from remote
        // storage and determine what needs to be pushed.

        let remoteHead: String? = (try? String(contentsOf: remoteHeadURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteStore = try ObjectStore(baseURL: remoteObjectsURL)

        let localReachable = try reachableHashes(from: head, using: storage)
        let remoteReachable = (remoteHead != nil && !remoteHead!.isEmpty) ? try reachableHashes(from: remoteHead!, using: remoteStore) : []

        let toPush = localReachable.subtracting(remoteReachable)
        if toPush.isEmpty {
            print("Nothing to push: remote up to date")
            return
        }

        for hash in toPush {
            let prefix = String(hash.prefix(2))
            let suffix = String(hash.dropFirst(2))
            let url = remoteObjectsURL.appendingPathComponent(prefix).appendingPathComponent(suffix)
            let object = try storage.retrieve(hash)
            _ = try await remote.put(url: url, data: object.content, mimetype: nil, etag: nil, privateKey: privateKey)
        }

        // Update remote HEAD
        _ = try await remote.put(url: remoteHeadURL, data: head.data(using: .utf8)!, mimetype: nil, etag: nil, privateKey: privateKey)

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

    private func reachableHashes(from rootHash: String, using objectStore: ObjectStore) throws -> Set<String> {
        var seen = Set<String>()
        var stack: [String] = [rootHash]

        while let hash = stack.popLast() {
            if seen.contains(hash) { continue }
            seen.insert(hash)

            // Try to load as Commit, then as Tree, else as Blob

            if let commit = try? objectStore.retrieve(hash, as: Commit.self) {
                if !commit.tree.isEmpty {
                    stack.append(commit.tree)
                }
                if !commit.parent.isEmpty && commit.parent != EmptyHash {
                    stack.append(commit.parent)
                }
            } else if let tree = try? objectStore.retrieve(hash, as: Tree.self) {
                for entry in tree.entries {
                    stack.append(entry.hash)
                }
            } // TODO: else: Blob or unknown, don't need to traverse further
        }
        return seen
    }

    private func writeManifest(_ commitHash: String) throws {
        let files = try tracked(commitHash: commitHash)
        let content = files.map {
            "\($0.mode) \($0.hash ?? "") \($0.path)"
        }.joined(separator: "\n")
        try content.write(to: witDir.appending(path: "manifest"), atomically: true, encoding: .utf8)
    }

    private func treeFilesChanged(_ treeHash: String?) throws -> [FileRef] {
        var changes: [FileRef] = []

        // Build a map of previous file states
        let previousFiles = try treeFiles(treeHash)

        // Scan current working directory
        let currentFiles = try files(within: baseURL)

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
        var out: [String: FileRef] = [:]
        guard let treeHash else { return out }
        let tree = try storage.retrieve(treeHash, as: Tree.self)
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
            if let hash = try? storage.computeHashMemoryMapped(fileURL) {
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
        // If this directory hasn't changed, reuse previous tree
        if changedSubitems[directory] == nil, let previousTree = previousTreeCache[directory] {
            return storage.computeHash(previousTree)
        }

        var entries: [Tree.Entry] = []
        let directoryURL = directory.isEmpty ? baseURL : baseURL.appending(path: directory)

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
        return try storage.store(tree)
    }

    private func treeStructure(_ treeHash: String, path: String = "") throws -> [String: Tree] {
        guard !treeHash.isEmpty else { return [:] }

        var out: [String: Tree] = [:]
        let tree = try storage.retrieve(treeHash, as: Tree.self)
        out[path] = tree

        for entry in tree.entries where entry.mode == .directory {
            let subPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
            let trees = try treeStructure(entry.hash, path: subPath)
            out.merge(trees) { (_, new) in new }
        }
        return out
    }

    private func shouldIgnore(path: String) -> Bool {
        if ignored.contains(path) {
            return true
        }
        for component in path.split(separator: "/").map(String.init) {
            if ignored.contains(component) {
                return true
            }
        }
        return false
    }

    private func log(_ commitHash: String, commit: Commit) {
        let timestamp = Int(commit.timestamp.timeIntervalSince1970)
        let timezone = timezoneOffset(commit.timestamp)
        let message = "\(commitHash) \(commit.parent) \(commit.author) \(timestamp) \(timezone) commit: \(commit.message)\n"

        if let fileHandle = FileHandle(forUpdatingAtPath: witDir.appending(path: "logs").path) {
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
                try message.write(to: witDir.appending(path: "logs"), atomically: true, encoding: .utf8)
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
