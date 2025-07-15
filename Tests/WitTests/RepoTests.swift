import Foundation
import Testing
@testable import Wit

@Suite("Repo Tests")
final class RepoTests {

    @Test("Clone")
    func clone() async throws {
        let (pathA, repoA) = NewRepo()
        defer { RemoveDirectory(pathA) }

        let repoA_Commit1_Hash = try await CommitFile(repoA, path: "Documents/foo.txt")
        let repoA_Commit2_Hash = try await CommitFile(repoA, path: "Documents/bar.txt")
        #expect(repoA_Commit1_Hash != repoA_Commit2_Hash)

        // Clone into new repo
        let (pathB, repoB) = NewRepo()
        defer { RemoveDirectory(pathB) }

        try await repoB.clone(repoA.disk)
        #expect(await repoB.retrieveHEAD() == repoA_Commit2_Hash)

        // Make commit and push into old repo
        let repoB_Commit3_Hash = try await CommitFile(repoB, path: "baz.txt")
        try await repoB.push(repoA.disk)
        #expect(await repoA.retrieveHEAD() == repoB_Commit3_Hash)
    }

    @Test("Status of working directory")
    func status() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.write("This is some foo", path: "Documents/foo.txt")
        try await repo.write("This is some bar", path: "Documents/bar.txt")

        let commit1_Hash = try await repo.commit("Initial commit")
        let commit1_Status = try await repo.status(.commit(commit1_Hash))
        #expect(commit1_Status.isEmpty == true)

        try await repo.write("Updated foo", path: "Documents/foo.txt")
        try await repo.write("This is some baz", path: "baz.txt")
        try await repo.delete("Documents/bar.txt")

        let status_WithChanges = try await repo.status()
        #expect(status_WithChanges.isEmpty == false)
        #expect(status_WithChanges.count == 3)
    }

    @Test("Commit changes")
    func commit() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        let commit1_Hash = try await CommitFile(repo, path: "Documents/foo.txt", message: "Initial commit")
        #expect(commit1_Hash.isEmpty == false)
        #expect(try await repo.objects.exists(commit1_Hash) == true)

        let head = await repo.retrieveHEAD()
        #expect(head == commit1_Hash)

        let commit1 = try await repo.objects.retrieve(commit1_Hash, as: Commit.self)
        #expect(commit1.message == "Initial commit")
        #expect(commit1.parent == "")

        let commit1_Tree = try await repo.objects.retrieve(commit1.tree, as: Tree.self)
        #expect(commit1_Tree.entries.count == 1)
        #expect(commit1_Tree.entries[0].name == "Documents")

        let commit1_TreeSubTree = try await repo.objects.retrieve(commit1_Tree.entries[0].hash, as: Tree.self)
        #expect(commit1_TreeSubTree.entries.count == 1)

        // Delete all files and commit changes
        try await repo.delete("Documents")
        let commit2_Hash = try await repo.commit("Deleted documents")
        let commit2 = try await repo.objects.retrieve(commit2_Hash, as: Commit.self)
        let commit2_Tree = try await repo.objects.retrieve(commit2.tree, as: Tree.self)
        #expect(commit2.parent == commit1_Hash)
        #expect(commit2_Tree.entries.count == 0)
    }

    @Test("File References")
    func fileReferences() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.write("This is some foo", path: "foo.txt")
        try await repo.write("This is some bar", path: "Documents/bar.txt")
        
        let references = try await repo.retrieveCurrentFileReferences()
        #expect(references.count == 2)
        #expect(references["foo.txt"]?.state == nil)
        #expect(references["Documents/bar.txt"]?.state == nil)
    }

    @Test("Tree optimization")
    func treeOptimizationTest() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.write("This is some foo", path: "foo.txt")
        try await repo.write("This is some bar", path: "Documents/bar.txt")
        try await repo.write("This is some baz", path: "Documents/Sub/baz.txt")

        let commit1_Hash = try await repo.commit("Initial commit")
        let commit1 = try await repo.objects.retrieve(commit1_Hash, as: Commit.self)
        let commit1_Tree = try await repo.objects.retrieve(commit1.tree, as: Tree.self)
        let commit1_TreeBarEntry = commit1_Tree.entries.first { $0.name == "Documents" }
        let commit1_TreeBarEntryHash = commit1_TreeBarEntry?.hash

        try await repo.write("Updated foo", path: "foo.txt")

        let commit2_Hash = try await repo.commit("Update file")
        let commit2 = try await repo.objects.retrieve(commit2_Hash, as: Commit.self)
        let commit2_Tree = try await repo.objects.retrieve(commit2.tree, as: Tree.self)
        let commit2_TreeBarEntry = commit2_Tree.entries.first { $0.name == "Documents" }!
        let commit2_TreeBarEntryHash = commit2_TreeBarEntry.hash
        #expect(commit1_TreeBarEntryHash == commit2_TreeBarEntryHash, "'bar' directory tree should be reused")
        #expect(commit1.tree != commit2.tree, "root tree should be different")

        let commit1_FooEntry = commit1_Tree.entries.first { $0.name == "foo.txt" }!
        let commit2_FooEntry = commit2_Tree.entries.first { $0.name == "foo.txt" }!
        #expect(commit1_FooEntry.hash != commit2_FooEntry.hash, "'foo' directory tree should be different")
    }

    @Test("Common Ancestor")
    func commonAncestor() async throws {
       // TODO: implement
    }
}
