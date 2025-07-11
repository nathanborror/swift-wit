import Foundation
import Testing
@testable import Wit

@Suite("Client Tests")
final class ClientTests {

    let workingPath: String
    let client: Client

    init() async throws {
        self.workingPath = UUID().uuidString
        self.client = Client(workingPath: workingPath, privateKey: .init())
    }

    deinit {
        try? FileManager.default.removeItem(at: .documentsDirectory/workingPath)
    }

    @Test("Show status of working directory")
    func status() async throws {
        try await client.write("This is some foo", path: "Documents/foo.txt")
        try await client.write("This is some bar", path: "Documents/bar.txt")

        let initialCommitHash = try await client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )
        let initialStatus = try await client.status(commitHash: initialCommitHash)
        #expect(initialStatus.hasChanges == false)

        try await client.write("Updated foo", path: "Documents/foo.txt")
        try await client.write("This is some baz", path: "baz.txt")
        try await client.delete("Documents/bar.txt")

        let status = try await client.status(commitHash: initialCommitHash)
        #expect(status.hasChanges)

        #expect(status.modified.count == 1)
        #expect(status.modified[0].hasSuffix("Documents/foo.txt"))

        #expect(status.deleted.count == 1)
        #expect(status.deleted[0].hasSuffix("Documents/bar.txt"))

        #expect(status.added.count == 1)
        #expect(status.added[0] == "baz.txt")
    }

    @Test("List tracked files in working directory")
    func tracked() async throws {
        try await client.write("This is some foo", path: "Documents/foo.txt")
        try await client.write("This is some bar", path: "Documents/bar.txt")

        let initialCommitHash = try await client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )

        let tracked = try await client.tracked(commitHash: initialCommitHash)
        #expect(tracked.count == 2)
        #expect(tracked.map { $0.path }.contains("Documents/bar.txt"))
        #expect(tracked.map { $0.path }.contains("Documents/foo.txt"))
    }

    @Test("Commit changes")
    func commit() async throws {
        try await client.write("This is some foo", path: "Documents/foo.txt")
        try await client.write("This is some bar", path: "Documents/bar.txt")

        let initialCommitHash = try await client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )
        #expect(initialCommitHash.isEmpty == false)
        #expect(try await client.store.exists(initialCommitHash) == true)

        let head = try await client.read(".wild/refs/heads/main")
        #expect(head == initialCommitHash)

        let initialCommit = try await client.store.retrieve(initialCommitHash, as: Commit.self)
        #expect(initialCommit.message == "Initial commit")
        #expect(initialCommit.parent == nil)

        let tree = try await client.store.retrieve(initialCommit.tree, as: Tree.self)
        #expect(tree.entries.count == 1)
        #expect(tree.entries[0].name == "Documents")

        let subTree = try await client.store.retrieve(tree.entries[0].hash, as: Tree.self)
        #expect(subTree.entries.count == 2)

        let manifest = try await client.read(".wild/manifest")
        #expect(manifest == """
            normal 5e0805e8e3e88f758cf56b1e4bee36eeeb7e7e7c062ea543756a72971482007a Documents/bar.txt
            normal 01a467a2e1c9531bbccdaeff8531feeb8c529e8208ad84a278d61a45f3c6a166 Documents/foo.txt
            """)

        // Delete all files and commit changes

        try await client.delete("Documents")

        let newCommitHash = try await client.commit(
            message: "Deleted documents",
            author: "Test User <test@example.com>",
            previousCommitHash: initialCommitHash
        )
        let newCommit = try await client.store.retrieve(newCommitHash, as: Commit.self)
        let newCommitTree = try await client.store.retrieve(newCommit.tree, as: Tree.self)
        #expect(newCommit.parent == initialCommitHash)
        #expect(newCommitTree.entries.count == 0)
    }

    @Test("Ensure tree optimization - unchanged subtrees are reused")
    func treeOptimizationTest() async throws {
        try await client.write("This is some foo", path: "foo.txt")
        try await client.write("This is some bar", path: "Documents/bar.txt")
        try await client.write("This is some baz", path: "Documents/Sub/baz.txt")

        let initialCommitHash = try await client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )
        let initialCommit = try await client.store.retrieve(initialCommitHash, as: Commit.self)
        let initialCommitTree = try await client.store.retrieve(initialCommit.tree, as: Tree.self)
        let initialCommitTreeBarEntry = initialCommitTree.entries.first { $0.name == "Documents" }
        let initialCommitTreeBarEntryHash = initialCommitTreeBarEntry?.hash

        try await client.write("Updated foo", path: "foo.txt")

        let newCommitHash = try await client.commit(
            message: "Update file",
            author: "Test User <test@example.com>",
            previousCommitHash: initialCommitHash
        )
        let newCommit = try await client.store.retrieve(newCommitHash, as: Commit.self)
        let newCommitTree = try await client.store.retrieve(newCommit.tree, as: Tree.self)
        let newCommitTreeBarEntry = newCommitTree.entries.first { $0.name == "Documents" }!
        let newCommitTreeBarEntryHash = newCommitTreeBarEntry.hash
        #expect(initialCommitTreeBarEntryHash == newCommitTreeBarEntryHash, "'bar' directory tree should be reused")
        #expect(initialCommit.tree != newCommit.tree, "root tree should be different")

        let initialFooEntry = initialCommitTree.entries.first { $0.name == "foo.txt" }!
        let newFooEntry = newCommitTree.entries.first { $0.name == "foo.txt" }!
        #expect(initialFooEntry.hash != newFooEntry.hash, "'foo' directory tree should be different")
    }
}
