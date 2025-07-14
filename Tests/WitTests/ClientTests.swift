import Foundation
import Testing
@testable import Wit

@Suite("Client Tests")
final class ClientTests {

    let workingPath: String
    let client: Repo

    init() async throws {
        self.workingPath = UUID().uuidString
        self.client = Repo(url: .documentsDirectory/workingPath)
        try await client.initialize()
    }

    deinit {
        try? FileManager.default.removeItem(at: .documentsDirectory/workingPath)
    }

    @Test("Show status of working directory")
    func status() async throws {
        try await client.write("This is some foo", path: "Documents/foo.txt")
        try await client.write("This is some bar", path: "Documents/bar.txt")

        let initialCommitHash = try await client.commit("Initial commit")
        let initialStatus = try await client.status(.commit(initialCommitHash))
        #expect(initialStatus.isEmpty == true)

        try await client.write("Updated foo", path: "Documents/foo.txt")
        try await client.write("This is some baz", path: "baz.txt")
        try await client.delete("Documents/bar.txt")

        let status = try await client.status()
        #expect(status.isEmpty == false)
        #expect(status.count == 3)
    }

    @Test("Commit changes")
    func commit() async throws {
        try await client.write("This is some foo", path: "Documents/foo.txt")
        try await client.write("This is some bar", path: "Documents/bar.txt")

        let initialCommitHash = try await client.commit("Initial commit")
        #expect(initialCommitHash.isEmpty == false)
        #expect(try await client.objects.exists(initialCommitHash) == true)

        let head = await client.retrieveHEAD()
        #expect(head == initialCommitHash)

        let initialCommit = try await client.objects.retrieve(initialCommitHash, as: Commit.self)
        #expect(initialCommit.message == "Initial commit")
        #expect(initialCommit.parent == "")

        let tree = try await client.objects.retrieve(initialCommit.tree, as: Tree.self)
        #expect(tree.entries.count == 1)
        #expect(tree.entries[0].name == "Documents")

        let subTree = try await client.objects.retrieve(tree.entries[0].hash, as: Tree.self)
        #expect(subTree.entries.count == 2)

        // Delete all files and commit changes

        try await client.delete("Documents")

        let newCommitHash = try await client.commit("Deleted documents")
        let newCommit = try await client.objects.retrieve(newCommitHash, as: Commit.self)
        let newCommitTree = try await client.objects.retrieve(newCommit.tree, as: Tree.self)
        #expect(newCommit.parent == initialCommitHash)
        #expect(newCommitTree.entries.count == 0)
    }

    @Test("Ensure tree optimization - unchanged subtrees are reused")
    func treeOptimizationTest() async throws {
        try await client.write("This is some foo", path: "foo.txt")
        try await client.write("This is some bar", path: "Documents/bar.txt")
        try await client.write("This is some baz", path: "Documents/Sub/baz.txt")

        let initialCommitHash = try await client.commit("Initial commit")
        let initialCommit = try await client.objects.retrieve(initialCommitHash, as: Commit.self)
        let initialCommitTree = try await client.objects.retrieve(initialCommit.tree, as: Tree.self)
        let initialCommitTreeBarEntry = initialCommitTree.entries.first { $0.name == "Documents" }
        let initialCommitTreeBarEntryHash = initialCommitTreeBarEntry?.hash

        try await client.write("Updated foo", path: "foo.txt")

        let newCommitHash = try await client.commit("Update file")
        let newCommit = try await client.objects.retrieve(newCommitHash, as: Commit.self)
        let newCommitTree = try await client.objects.retrieve(newCommit.tree, as: Tree.self)
        let newCommitTreeBarEntry = newCommitTree.entries.first { $0.name == "Documents" }!
        let newCommitTreeBarEntryHash = newCommitTreeBarEntry.hash
        #expect(initialCommitTreeBarEntryHash == newCommitTreeBarEntryHash, "'bar' directory tree should be reused")
        #expect(initialCommit.tree != newCommit.tree, "root tree should be different")

        let initialFooEntry = initialCommitTree.entries.first { $0.name == "foo.txt" }!
        let newFooEntry = newCommitTree.entries.first { $0.name == "foo.txt" }!
        #expect(initialFooEntry.hash != newFooEntry.hash, "'foo' directory tree should be different")
    }
}
