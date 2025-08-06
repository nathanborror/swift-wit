import Foundation
import Testing
@testable import Wit

@Suite("Repo Tests")
final class RepoTests {

    @Test("Clone")
    func clone() async throws {
        let (pathA, repoA) = NewRepo()
        let (pathB, repoB) = NewRepo()

        defer { RemoveDirectory(pathA) }
        defer { RemoveDirectory(pathB) }

        // RepoA first two commits
        try await repoA.initialize()
        let repoA_Commit1_Hash = try await CommitFile(repoA, path: "Documents/foo.txt")
        let repoA_Commit2_Hash = try await CommitFile(repoA, path: "Documents/bar.txt")
        #expect(repoA_Commit1_Hash != repoA_Commit2_Hash)

        // RepoB clone
        try await repoB.clone(repoA.disk)
        let repoB_HEAD = await repoB.HEAD()!
        let repoB_HEAD_Commit = try await repoB.objects.retrieve(repoB_HEAD, as: Commit.self)
        let repoB_HEAD_Commit_Tree = try await repoB.objects.retrieve(repoB_HEAD_Commit.tree, as: Tree.self)
        #expect(repoB_HEAD == repoA_Commit2_Hash)
        #expect(repoB_HEAD_Commit_Tree.entries.count == 1)

        // RepoB commit
        let repoB_Commit3_Hash = try await CommitFile(repoB, path: "baz.txt")
        let repoB_Commit3 = try await repoB.objects.retrieve(repoB_Commit3_Hash, as: Commit.self)
        let repoB_Commit3_Tree = try await repoB.objects.retrieve(repoB_Commit3.tree, as: Tree.self)
        #expect(repoB_Commit3_Tree.entries.count == 2)

        // RepoB push to RepoA
        try await repoB.push(repoA.disk)
        #expect(await repoA.HEAD() == repoB_Commit3_Hash)
    }

    @Test("Rebase")
    func rebase() async throws {
        let (pathA, repoA) = NewRepo()
        let (pathB, repoB) = NewRepo()

        defer { RemoveDirectory(pathA) }
        defer { RemoveDirectory(pathB) }

        // RepoA → Commit 1
        try await repoA.initialize()
        let repoA_Commit1_Hash = try await CommitFile(repoA, path: "foo.txt")

        // RepoB clone RepoA
        try await repoB.clone(repoA.disk)
        #expect(await repoB.HEAD() == repoA_Commit1_Hash)

        // RepoA → Commit 2
        let repoA_Commit2_Hash = try await CommitFile(repoA, path: "bar.txt")
        let repoA_Commit2_Commit = try await repoA.objects.retrieve(repoA_Commit2_Hash, as: Commit.self)
        let repoA_Commit2_Tree = try await repoA.objects.retrieve(repoA_Commit2_Commit.tree, as: Tree.self)
        #expect(repoA_Commit2_Tree.entries.count == 2)

        // RepoB → Commit 3
        let repoB_Commit3_Hash = try await CommitFile(repoB, path: "baz.txt")
        let repoB_Commit3_Commit = try await repoB.objects.retrieve(repoB_Commit3_Hash, as: Commit.self)
        let repoB_Commit3_Tree = try await repoB.objects.retrieve(repoB_Commit3_Commit.tree, as: Tree.self)
        #expect(repoB_Commit3_Tree.entries.count == 2)

        // RepoB Rebase
        let repoB_HEAD = try await repoB.rebase(repoA.disk)
        let repoB_HEAD_commit = try await repoB.objects.retrieve(repoB_HEAD, as: Commit.self)
        let repoB_HEAD_tree = try await repoB.objects.retrieve(repoB_HEAD_commit.tree, as: Tree.self)
        #expect(repoB_HEAD_tree.entries.count == 3)
    }

    @Test("Status of working directory")
    func status() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.initialize()
        try await repo.write("This is some foo", path: "Documents/foo.txt")
        try await repo.write("This is some bar", path: "Documents/bar.txt")

        let commit1_Hash = try await repo.commit("Initial commit")
        let commit1_Status = try await repo.status(.commit(commit1_Hash))
        #expect(commit1_Status.isEmpty == true)

        try await repo.write("Updated foo", path: "Documents/foo.txt")
        try await repo.write("This is some baz", path: "Documents/Folder/baz.txt")
        try await repo.delete("Documents/bar.txt")

        let status1_WithChanges = try await repo.status()
        #expect(status1_WithChanges.isEmpty == false)
        #expect(status1_WithChanges.count == 3)

        let commit2_Hash = try await repo.commit("Updated files")
        #expect(commit1_Hash != commit2_Hash)

        let status2_WithChanges = try await repo.status()
        #expect(status2_WithChanges.isEmpty == true)
        #expect(status2_WithChanges.count == 0)
    }

    @Test("Commit changes")
    func commit() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.initialize()
        let commit1_Hash = try await CommitFile(repo, path: "Documents/foo.txt", message: "Initial commit")
        #expect(commit1_Hash.isEmpty == false)
        #expect(try await repo.objects.exists(commit1_Hash) == true)

        let head = await repo.HEAD()
        #expect(head == commit1_Hash)

        let commit1 = try await repo.objects.retrieve(commit1_Hash, as: Commit.self)
        #expect(commit1.message == "Initial commit")
        #expect(commit1.parent == nil)

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
