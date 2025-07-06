import Foundation
import Testing
@testable import Wit

@Suite("Client Tests")
struct ClientTests {

    @Test("Show status of working directory")
    func status() async throws {
        let baseURL = URL.documentsDirectory.appending(path: "test-client-status")
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let client = try Client(baseURL)
        let dir = baseURL.appending(path: "Documents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try "This is some foo".write(to: dir.appending(path: "foo.txt"), atomically: true, encoding: .utf8)
        try "This is some bar".write(to: dir.appending(path: "bar.txt"), atomically: true, encoding: .utf8)

        let initialCommitHash = try client.commit(
            message: "Initial structure",
            author: "Test User <test@example.com>"
        )
        let initialStatus = try client.status(commitHash: initialCommitHash)
        #expect(initialStatus.hasChanges == false)

        try "Updated foo".write(to: dir.appending(path: "foo.txt"), atomically: true, encoding: .utf8)
        try "This is some baz".write(to: baseURL.appending(path: "baz.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: dir.appending(path: "bar.txt"))

        let status = try client.status(commitHash: initialCommitHash)
        #expect(status.hasChanges)

        #expect(status.modified.count == 1)
        #expect(status.modified[0] == "Documents/foo.txt")

        #expect(status.deleted.count == 1)
        #expect(status.deleted[0] == "Documents/bar.txt")

        #expect(status.added.count == 1)
        #expect(status.added[0] == "baz.txt")
    }

    @Test("List tracked files in working directory")
    func tracked() async throws {
        let baseURL = URL.documentsDirectory.appending(path: "test-client-tracked")
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let client = try Client(baseURL)
        let fooDir = baseURL.appending(path: "foo")
        try FileManager.default.createDirectory(at: fooDir, withIntermediateDirectories: true)
        try "This is some foo".write(to: fooDir.appending(path: "foo.txt"), atomically: true, encoding: .utf8)
        try "This is some bar".write(to: fooDir.appending(path: "bar.txt"), atomically: true, encoding: .utf8)
        let initialCommitHash = try client.commit(
            message: "Initial structure",
            author: "Test User <test@example.com>"
        )

        let tracked = try client.tracked(commitHash: initialCommitHash)
        #expect(tracked.count == 2)
        #expect(tracked[0].path == "foo/bar.txt")
        #expect(tracked[1].path == "foo/foo.txt")
    }

    @Test("Commit changes")
    func commit() async throws {
        let baseURL = URL.documentsDirectory.appending(path: "test-client-commit")
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let client = try Client(baseURL)
        let dir = baseURL.appending(path: "documents")
        let subDir = dir.appending(path: "subdir")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        try "This is some foo".write(to: dir.appending(path: "foo.txt"), atomically: true, encoding: .utf8)
        try "This is some bar".write(to: subDir.appending(path: "bar.txt"), atomically: true, encoding: .utf8)

        let initialCommitHash = try client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )
        #expect(initialCommitHash.isEmpty == false)
        #expect(try client.storage.exists(hash: initialCommitHash))
        #expect(client.head == initialCommitHash)

        let initialCommit = try client.storage.retrieve(initialCommitHash, as: Commit.self)
        #expect(initialCommit.message == "Initial commit")
        #expect(initialCommit.parent == EmptyHash)

        let tree = try client.storage.retrieve(initialCommit.tree, as: Tree.self)
        #expect(tree.entries.count == 1)
        #expect(tree.entries[0].name == "documents")

        let subTree = try client.storage.retrieve(tree.entries[0].hash, as: Tree.self)
        #expect(subTree.entries.count == 2)

        // Delete all files and commit changes

        try FileManager.default.removeItem(at: dir)
        let newCommitHash = try client.commit(
            message: "Deleted documents",
            author: "Test User <test@example.com>",
            previousCommitHash: initialCommitHash
        )
        let newCommit = try client.storage.retrieve(newCommitHash, as: Commit.self)
        let newCommitTree = try client.storage.retrieve(newCommit.tree, as: Tree.self)
        #expect(newCommit.parent == initialCommitHash)
        #expect(newCommitTree.entries.count == 0)
    }

    @Test("Ensure tree optimization - unchanged subtrees are reused")
    func treeOptimizationTest() async throws {
        let baseURL = URL.documentsDirectory.appending(path: "test-client-tree-optimization")
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let client = try Client(baseURL)

        // Create initial directory structure
        let dir = baseURL.appending(path: "dir")
        let subDir = dir.appending(path: "subdir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        // Add files
        try "This is some foo".write(to: baseURL.appending(path: "foo.txt"), atomically: true, encoding: .utf8)
        try "This is some bar".write(to: dir.appending(path: "bar.txt"), atomically: true, encoding: .utf8)
        try "This is some baz".write(to: subDir.appending(path: "baz.txt"), atomically: true, encoding: .utf8)

        let initialCommitHash = try client.commit(
            message: "Initial structure",
            author: "Test User <test@example.com>"
        )
        let initialCommit = try client.storage.retrieve(initialCommitHash, as: Commit.self)
        let initialCommitTree = try client.storage.retrieve(initialCommit.tree, as: Tree.self)
        let initialCommitTreeBarEntry = initialCommitTree.entries.first { $0.name == "dir" }!
        let initialCommitTreeBarEntryHash = initialCommitTreeBarEntry.hash

        try "Updated foo".write(to: baseURL.appending(path: "foo.txt"), atomically: true, encoding: .utf8)

        let newCommitHash = try client.commit(
            message: "Update dir/subdir/baz.txt only",
            author: "Test User <test@example.com>",
            previousCommitHash: initialCommitHash
        )
        let newCommit = try client.storage.retrieve(newCommitHash, as: Commit.self)
        let newCommitTree = try client.storage.retrieve(newCommit.tree, as: Tree.self)
        let newCommitTreeBarEntry = newCommitTree.entries.first { $0.name == "dir" }!
        let newCommitTreeBarEntryHash = newCommitTreeBarEntry.hash
        #expect(initialCommitTreeBarEntryHash == newCommitTreeBarEntryHash, "'bar' directory tree should be reused")
        #expect(initialCommit.tree != newCommit.tree, "root tree should be different")

        let initialFooEntry = initialCommitTree.entries.first { $0.name == "foo.txt" }!
        let newFooEntry = newCommitTree.entries.first { $0.name == "foo.txt" }!
        #expect(initialFooEntry.hash != newFooEntry.hash, "'foo' directory tree should be different")
    }
}
