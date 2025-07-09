import Foundation
import Testing
@testable import Wit

@Suite("Client Tests")
struct ClientTests {

    func cleanup(_ userID: String) {
        try? FileManager.default.removeItem(at: .documentsDirectory.appending(path: userID))
    }

    @Test("Show status of working directory")
    func status() async throws {
        let userID = "test-client-status"
        defer { cleanup(userID) }

        let client = try Client()
        try await client.register(userID: userID, privateKey: .init())
        try client.write("This is some foo", to: "Documents/foo.txt")
        try client.write("This is some bar", to: "Documents/bar.txt")

        let initialCommitHash = try client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )
        let initialStatus = try client.status(commitHash: initialCommitHash)
        #expect(initialStatus.hasChanges == false)

        try client.write("Updated foo", to: "Documents/foo.txt")
        try client.write("This is some baz", to: "baz.txt")
        try client.delete("Documents/bar.txt")

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
        let userID = "test-client-tracked"
        defer { cleanup(userID) }

        let client = try Client()
        try await client.register(userID: userID, privateKey: .init())
        try client.write("This is some foo", to: "Documents/foo.txt")
        try client.write("This is some bar", to: "Documents/bar.txt")

        let initialCommitHash = try client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )

        let tracked = try client.tracked(commitHash: initialCommitHash)
        #expect(tracked.count == 2)
        #expect(tracked.map { $0.path }.contains("Documents/bar.txt"))
        #expect(tracked.map { $0.path }.contains("Documents/foo.txt"))
    }

    @Test("Commit changes")
    func commit() async throws {
        let userID = "test-client-commit"
        defer { cleanup(userID) }

        let client = try Client()
        try await client.register(userID: userID, privateKey: .init())
        try client.write("This is some foo", to: "Documents/foo.txt")
        try client.write("This is some bar", to: "Documents/bar.txt")

        let initialCommitHash = try client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )
        #expect(initialCommitHash.isEmpty == false)
        #expect(try client.localStorage?.exists(hash: initialCommitHash) == true)

        let head = client.read(".wild/HEAD")
        #expect(head == initialCommitHash)

        let initialCommit = try client.localStorage?.retrieve(initialCommitHash, as: Commit.self)
        #expect(initialCommit?.message == "Initial commit")
        #expect(initialCommit?.parent == nil)

        let tree = try client.localStorage?.retrieve(initialCommit!.tree, as: Tree.self)
        #expect(tree?.entries.count == 1)
        #expect(tree?.entries[0].name == "Documents")

        let subTree = try client.localStorage?.retrieve(tree!.entries[0].hash, as: Tree.self)
        #expect(subTree?.entries.count == 2)

        let manifest = client.read(".wild/manifest")
        #expect(manifest == """
            normal 5e0805e8e3e88f758cf56b1e4bee36eeeb7e7e7c062ea543756a72971482007a Documents/bar.txt
            normal 01a467a2e1c9531bbccdaeff8531feeb8c529e8208ad84a278d61a45f3c6a166 Documents/foo.txt
            """)

        // Delete all files and commit changes

        try client.delete("Documents")

        let newCommitHash = try client.commit(
            message: "Deleted documents",
            author: "Test User <test@example.com>",
            previousCommitHash: initialCommitHash
        )
        let newCommit = try client.localStorage?.retrieve(newCommitHash, as: Commit.self)
        let newCommitTree = try client.localStorage?.retrieve(newCommit!.tree, as: Tree.self)
        #expect(newCommit?.parent == initialCommitHash)
        #expect(newCommitTree?.entries.count == 0)
    }

    @Test("Ensure tree optimization - unchanged subtrees are reused")
    func treeOptimizationTest() async throws {
        let userID = "test-client-tree-optimization"
        defer { cleanup(userID) }

        let client = try Client()
        try await client.register(userID: userID, privateKey: .init())
        try client.write("This is some foo", to: "foo.txt")
        try client.write("This is some bar", to: "Documents/bar.txt")
        try client.write("This is some baz", to: "Documents/Sub/baz.txt")

        let initialCommitHash = try client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )
        let initialCommit = try client.localStorage?.retrieve(initialCommitHash, as: Commit.self)
        let initialCommitTree = try client.localStorage?.retrieve(initialCommit!.tree, as: Tree.self)
        let initialCommitTreeBarEntry = initialCommitTree?.entries.first { $0.name == "Documents" }!
        let initialCommitTreeBarEntryHash = initialCommitTreeBarEntry?.hash

        try client.write("Updated foo", to: "foo.txt")

        let newCommitHash = try client.commit(
            message: "Update file",
            author: "Test User <test@example.com>",
            previousCommitHash: initialCommitHash
        )
        let newCommit = try client.localStorage?.retrieve(newCommitHash, as: Commit.self)
        let newCommitTree = try client.localStorage?.retrieve(newCommit!.tree, as: Tree.self)
        let newCommitTreeBarEntry = newCommitTree?.entries.first { $0.name == "Documents" }!
        let newCommitTreeBarEntryHash = newCommitTreeBarEntry?.hash
        #expect(initialCommitTreeBarEntryHash == newCommitTreeBarEntryHash, "'bar' directory tree should be reused")
        #expect(initialCommit?.tree != newCommit?.tree, "root tree should be different")

        let initialFooEntry = initialCommitTree?.entries.first { $0.name == "foo.txt" }!
        let newFooEntry = newCommitTree?.entries.first { $0.name == "foo.txt" }!
        #expect(initialFooEntry?.hash != newFooEntry?.hash, "'foo' directory tree should be different")
    }
}
