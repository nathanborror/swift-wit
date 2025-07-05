import Foundation
import Testing
@testable import Wit

@Suite("Client Tests")
struct ClientTests {

    @Test("Status")
    func status() async throws {
        let workingURL = URL.documentsDirectory.appending(path: "test-client-status")
        defer { try? FileManager.default.removeItem(at: workingURL) }

        let client = try Client(workingURL: workingURL)
        let dir = workingURL.appending(path: "Documents")
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
        try "This is some baz".write(to: workingURL.appending(path: "baz.txt"), atomically: true, encoding: .utf8)
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

    @Test("List tracked files")
    func listTrackedFiles() async throws {
        let workingURL = URL.documentsDirectory.appending(path: "test-client-list")
        defer { try? FileManager.default.removeItem(at: workingURL) }

        let client = try Client(workingURL: workingURL)
        let fooDir = workingURL.appending(path: "foo")
        try FileManager.default.createDirectory(at: fooDir, withIntermediateDirectories: true)
        try "This is some foo".write(to: fooDir.appending(path: "foo.txt"), atomically: true, encoding: .utf8)
        try "This is some bar".write(to: fooDir.appending(path: "bar.txt"), atomically: true, encoding: .utf8)
        let initialCommitHash = try client.commit(
            message: "Initial structure",
            author: "Test User <test@example.com>"
        )

        let tracked = try client.listTrackedFiles(commitHash: initialCommitHash)
        #expect(tracked.count == 2)
        #expect(tracked[0].path == "foo/bar.txt")
        #expect(tracked[1].path == "foo/foo.txt")
    }

    @Test("Commit")
    func commit() async throws {
        let workingURL = URL.documentsDirectory.appending(path: "test-client-commit")
        defer { try? FileManager.default.removeItem(at: workingURL) }

        let client = try Client(workingURL: workingURL)

        let doc = "This is my document"
        let docURL = workingURL.appending(path: "README.md")
        try doc.write(to: docURL, atomically: true, encoding: .utf8)

        let commitHash = try client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )
        #expect(commitHash.isEmpty == false)
        #expect(try client.storage.exists(hash: commitHash))
        #expect(client.HEAD == commitHash)

        let commit = try client.storage.retrieve(commitHash, as: Commit.self)
        #expect(commit.message == "Initial commit")
        #expect(commit.parent.isEmpty)

        let tree = try client.storage.retrieve(commit.tree, as: Tree.self)
        #expect(tree.entries.count == 1)
        #expect(tree.entries[0].name == "README.md")

        let blob = try client.storage.retrieve(tree.entries[0].hash, as: Blob.self)
        #expect(blob.content.count > 0)
    }

    @Test("Tree optimization - unchanged subtrees are reused")
    func treeOptimizationTest() async throws {
        let workingURL = URL.documentsDirectory.appending(path: "test-client-tree-optimization")
        defer { try? FileManager.default.removeItem(at: workingURL) }

        let client = try Client(workingURL: workingURL)

        // Create initial directory structure
        let fooDir = workingURL.appending(path: "foo")
        let barDir = workingURL.appending(path: "bar")
        try FileManager.default.createDirectory(at: fooDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: barDir, withIntermediateDirectories: true)

        // Add files
        try "This is some foo".write(to: fooDir.appending(path: "foo.txt"), atomically: true, encoding: .utf8)
        try "This is some bar".write(to: barDir.appending(path: "bar.txt"), atomically: true, encoding: .utf8)
        try "This is some baz".write(to: barDir.appending(path: "baz.txt"), atomically: true, encoding: .utf8)

        let initialCommitHash = try client.commit(
            message: "Initial structure",
            author: "Test User <test@example.com>"
        )
        let initialCommit = try client.storage.retrieve(initialCommitHash, as: Commit.self)
        let initialCommitTree = try client.storage.retrieve(initialCommit.tree, as: Tree.self)
        let initialCommitTreeBarEntry = initialCommitTree.entries.first { $0.name == "bar" }!
        let initialCommitTreeBarEntryHash = initialCommitTreeBarEntry.hash

        try "Updated foo".write(to: fooDir.appending(path: "foo.txt"), atomically: true, encoding: .utf8)

        let newCommitHash = try client.commit(
            message: "Update main.swift only",
            author: "Test User <test@example.com>",
            previousCommitHash: initialCommitHash
        )
        let newCommit = try client.storage.retrieve(newCommitHash, as: Commit.self)
        let newCommitTree = try client.storage.retrieve(newCommit.tree, as: Tree.self)
        let newCommitTreeBarEntry = newCommitTree.entries.first { $0.name == "bar" }!
        let newCommitTreeBarEntryHash = newCommitTreeBarEntry.hash
        #expect(initialCommitTreeBarEntryHash == newCommitTreeBarEntryHash, "'bar' directory tree should be reused")
        #expect(initialCommit.tree != newCommit.tree, "root tree should be different")

        let initialFooEntry = initialCommitTree.entries.first { $0.name == "foo" }!
        let newFooEntry = newCommitTree.entries.first { $0.name == "foo" }!
        #expect(initialFooEntry.hash != newFooEntry.hash, "'foo' directory tree should be different")
    }
}
