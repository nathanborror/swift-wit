import Foundation

public let WIT_DIR_NAME = ".wit"
public let WIT_IGNORE: Set<String> = [WIT_DIR_NAME, ".DS_Store"]

public final class Client {
    let baseURL: URL
    let witBaseURL: URL
    let witHeadURL: URL
    let witManifestURL: URL

    let storage: ObjectStore
    let ignored: Set<String>

    public init(baseURL: URL, ignorePaths: Set<String> = []) throws {
        self.baseURL = baseURL
        self.witBaseURL = baseURL.appending(path: WIT_DIR_NAME)
        self.witHeadURL = witBaseURL.appending(path: "HEAD")
        self.witManifestURL = witBaseURL.appending(path: "manifest")

        self.storage = try ObjectStore(baseURL: witBaseURL)
        self.ignored = ignorePaths.union(WIT_IGNORE)
    }

    public var HEAD: String? {
        try? readHEAD()
    }

    public func status(commitHash: String? = nil) throws -> Status {
        let commitHash = commitHash ?? HEAD ?? ""
        let commit = try storage.retrieve(commitHash, as: Commit.self)
        let changed = filesChanged(treeHash: commit.tree)
        return .init(
            modified: changed.filter { $0.kind == .modified }.map { $0.path },
            added: changed.filter { $0.kind == .added }.map { $0.path },
            deleted: changed.filter { $0.kind == .deleted }.map { $0.path }
        )
    }

    public func commit(message: String, author: String, timestamp: Date = .now, previousCommitHash: String = "") throws -> String {
        let previousCommit = try? storage.retrieve(previousCommitHash, as: Commit.self)
        let changed = filesChanged(treeHash: previousCommit?.tree)

        var blobHashes: [String: String] = [:]
        var changedFilePaths: Set<String> = []

        for file in changed {
            let fileURL = baseURL.appending(path: file.path)
            let fileData = try Data(contentsOf: fileURL)
            let blob = Blob(content: fileData)
            let hash = try storage.store(blob)
            blobHashes[file.path] = hash
            changedFilePaths.insert(file.path)
        }

        // Build new tree structure
        let treeHash = try updateTreesForChangedPaths(
            changedPaths: changedFilePaths,
            blobHashes: blobHashes,
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

        try writeHEAD(commitHash: commitHash)
        try writeManifest(commitHash: commitHash)
        return commitHash
    }

    public func listTrackedFiles(commitHash: String? = nil) throws -> [FileRef] {
        let commitHash = commitHash ?? HEAD ?? ""
        if commitHash.isEmpty {
            return []
        }
        let commit = try storage.retrieve(commitHash, as: Commit.self)
        var files: [String: FileRef] = [:]
        try filesFromTree(treeHash: commit.tree, path: "", into: &files)
        return files.values.sorted { $0.path < $1.path }
    }

    // MARK: Private

    private func readHEAD() throws -> String? {
        guard FileManager.default.fileExists(atPath: witHeadURL.path) else {
            return nil
        }
        let out = try String(contentsOf: witHeadURL, encoding: .utf8)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeHEAD(commitHash: String) throws {
        try commitHash.write(to: witHeadURL, atomically: true, encoding: .utf8)
    }

    private func writeManifest(commitHash: String) throws {
        let files = try listTrackedFiles(commitHash: commitHash)
        let content = files.map {
            "\($0.mode) \($0.hash ?? "") \($0.path)"
        }.joined(separator: "\n")
        try content.write(to: witManifestURL, atomically: true, encoding: .utf8)
    }

    private func filesChanged(treeHash: String?) -> [FileRef] {
        var changes: [FileRef] = []

        // Build a map of previous file states
        var previousFiles: [String: FileRef] = [:]
        try? filesFromTree(treeHash: treeHash, into: &previousFiles)

        // Scan current working directory
        var currentFiles: [String: FileRef] = [:]
        try? filesFromURL(url: baseURL, into: &currentFiles)

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

    private func filesFromTree(treeHash: String?, path: String = "", into files: inout [String: FileRef]) throws {
        guard let treeHash else { return }
        let tree = try storage.retrieve(treeHash, as: Tree.self)
        for entry in tree.entries {
            let fullPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
            if entry.mode == "040000" { // Directory, recurse
                try filesFromTree(treeHash: entry.hash, path: fullPath, into: &files)
            } else {
                files[fullPath] = .init(path: fullPath, hash: entry.hash, mode: entry.mode)
            }
        }
    }

    private func filesFromURL(url: URL, into files: inout [String: FileRef]) throws {
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let relativePath = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                guard !shouldIgnore(path: relativePath) else { continue }
                guard let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile else {
                    continue
                }
                if let hash = try? storage.computeHashMemoryMapped(fileURL) {
                    files[relativePath] = .init(path: relativePath, hash: hash, mode: "100644")
                }
            }
        }
    }

    // TODO: Review — was generated
    private func updateTreesForChangedPaths(changedPaths: Set<String>, blobHashes: [String: String], previousTreeHash: String) throws -> String {
        var changesByDirectory: [String: Set<String>] = [:]

        for path in changedPaths {
            let components = path.split(separator: "/")
            var currentPath = ""

            // Mark all parent directories as changed
            for i in 0..<components.count-1 {
                if !currentPath.isEmpty { currentPath += "/" }
                currentPath += components[i]
                changesByDirectory[currentPath, default: []].insert(String(components[i+1]))
            }

            // Root directory
            changesByDirectory["", default: []].insert(String(components[0]))
        }

        // Load previous tree structure
        let previousTreeCache = try loadPreviousTreeStructure(previousTreeHash)

        // Build trees bottom-up
        return try buildTreeRecursively(
            directory: "",
            changedSubitems: changesByDirectory,
            blobHashes: blobHashes,
            previousTreeCache: previousTreeCache
        )
    }

    // TODO: Review — was generated
    private func buildTreeRecursively(directory: String, changedSubitems: [String: Set<String>], blobHashes: [String: String], previousTreeCache: [String: Tree]) throws -> String {
        // If this directory hasn't changed, reuse previous tree
        if changedSubitems[directory] == nil,
           let previousTree = previousTreeCache[directory] {
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
                    blobHashes: blobHashes,
                    previousTreeCache: previousTreeCache
                )
                entries.append(.init(mode: "040000", name: name, hash: subTreeHash))
            } else {
                // Use new blob hash or get from previous tree
                if let blobHash = blobHashes[relativePath] {
                    entries.append(.init(mode: "100644", name: name, hash: blobHash))
                } else if let previousTree = previousTreeCache[directory],
                          let previousEntry = previousTree.entries.first(where: { $0.name == name }) {
                    entries.append(previousEntry)
                }
            }
        }

        let tree = Tree(entries: entries)
        return try storage.store(tree)
    }

    // TODO: Review — was generated
    private func loadPreviousTreeStructure(_ rootTreeHash: String) throws -> [String: Tree] {
        var cache: [String: Tree] = [:]

        guard !rootTreeHash.isEmpty else { return cache }

        func loadTreeRecursive(hash: String, path: String) throws {
            let tree = try storage.retrieve(hash, as: Tree.self)
            cache[path] = tree

            for entry in tree.entries where entry.mode == "040000" {
                let subPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
                try loadTreeRecursive(hash: entry.hash, path: subPath)
            }
        }

        try loadTreeRecursive(hash: rootTreeHash, path: "")
        return cache
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
}
