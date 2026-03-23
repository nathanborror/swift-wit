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

        // Make two commits within Repo-A
        try await repoA.initialize()
        let repoA_Commit1_Hash = try await CommitFile(repoA, path: "foo.txt")
        let repoA_Commit2_Hash = try await CommitFile(repoA, path: "bar.txt")
        #expect(repoA_Commit1_Hash != repoA_Commit2_Hash)

        // Clone Repo-A into Repo-B
        try await repoB.clone(repoA.remoteLocal)
        let repoB_HEAD = await repoB.readHEAD(remote: repoB.remoteLocal)!
        let repoB_HEAD_Commit = try await repoB.objects.retrieve(commit: repoB_HEAD)
        let repoB_HEAD_Commit_Tree = try await repoB.objects.retrieve(tree: repoB_HEAD_Commit.tree)
        #expect(repoB_HEAD == repoA_Commit2_Hash)
        #expect(repoB_HEAD_Commit_Tree.entries.count == 2)

        // Commit a new file into Repo-B
        let repoB_Commit3_Hash = try await CommitFile(repoB, path: "baz.txt")
        let repoB_Commit3 = try await repoB.objects.retrieve(commit: repoB_Commit3_Hash)
        let repoB_Commit3_Tree = try await repoB.objects.retrieve(tree: repoB_Commit3.tree)
        #expect(repoB_Commit3_Tree.entries.count == 3)

        // Push Repo-B to Repo-A
        try await repoB.push(repoA.remoteLocal)
        #expect(await repoA.readHEAD(remote: repoA.remoteLocal) == repoB_Commit3_Hash)
    }

    @Test("Rebase")
    func rebase() async throws {
        let (pathA, repoA) = NewRepo()
        let (pathB, repoB) = NewRepo()

        defer { RemoveDirectory(pathA) }
        defer { RemoveDirectory(pathB) }

        // Commit one file to Repo-A (commit 1)
        try await repoA.initialize()
        let repoA_commit1_hash = try await CommitFile(repoA, path: "foo.txt")

        // Clone Repo-A into Repo-B
        try await repoB.clone(repoA.remoteLocal)
        #expect(await repoB.readHEAD(remote: repoB.remoteLocal) == repoA_commit1_hash)

        // Commit a new file to Repo-A (commit 2)
        let repoA_commit2_hash = try await CommitFile(repoA, path: "bar.txt")
        let repoA_commit2_commit = try await repoA.objects.retrieve(commit: repoA_commit2_hash)
        let repoA_commit2_tree = try await repoA.objects.retrieve(tree: repoA_commit2_commit.tree)
        #expect(repoA_commit2_tree.entries.count == 2)

        // Commit a new file to Repo-B (commit 3)
        let repoB_commit3_hash = try await CommitFile(repoB, path: "baz.txt")
        let repoB_commit3_commit = try await repoB.objects.retrieve(commit: repoB_commit3_hash)
        let repoB_commit3_tree = try await repoB.objects.retrieve(tree: repoB_commit3_commit.tree)
        #expect(repoB_commit3_tree.entries.count == 2)

        let repoB_logs1 = try await repoB.logs()
        #expect(repoB_logs1.count == 2)

        // Rebase Repo-B
        let repoB_HEAD = try await repoB.rebase(repoA.remoteLocal)
        let repoB_HEAD_commit = try await repoB.objects.retrieve(commit: repoB_HEAD)
        let repoB_HEAD_tree = try await repoB.objects.retrieve(tree: repoB_HEAD_commit.tree)
        #expect(repoB_HEAD_tree.entries.count == 3)

        let statusA = try await repoA.status()
        #expect(statusA.isEmpty == true)
        
        let statusB = try await repoB.status()
        #expect(statusB.isEmpty == true)

        let repoB_logs2 = try await repoB.logs()
        #expect(repoB_logs2.count == 3)
    }

    @Test("Status of working directory")
    func status() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.initialize()
        try await repo.write("This is some foo", path: "Documents/foo.txt")
        try await repo.write("This is some bar", path: "Documents/bar.txt")
        try await repo.write("", path: ".DS_Store") // Should be ignored

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
        try await repo.write("", path: ".DS_Store") // Should be ignored
        try await repo.write("", path: "Documents/foo.txt")
        let commit1_Hash = try await repo.commit("Initial commit")
        #expect(commit1_Hash.isEmpty == false)
        #expect(try await repo.objects.exists(key: .init(hash: commit1_Hash, kind: .commit)) == true)

        let head = await repo.readHEAD(remote: repo.remoteLocal)
        #expect(head == commit1_Hash)

        let commit1 = try await repo.objects.retrieve(commit: commit1_Hash)
        #expect(commit1.message == "Initial commit")
        #expect(commit1.parent == nil)

        let commit1_Tree = try await repo.objects.retrieve(tree: commit1.tree)
        #expect(commit1_Tree.entries.count == 1)
        #expect(commit1_Tree.entries[0].name == "Documents")

        let commit1_TreeSubTree = try await repo.objects.retrieve(tree: commit1_Tree.entries[0].hash)
        #expect(commit1_TreeSubTree.entries.count == 1)

        // Delete all files and commit changes
        try await repo.delete("Documents")
        let commit2_Hash = try await repo.commit("Deleted documents")
        let commit2 = try await repo.objects.retrieve(commit: commit2_Hash)
        let commit2_Tree = try await repo.objects.retrieve(tree: commit2.tree)
        #expect(commit2.parent == commit1_Hash)
        #expect(commit2_Tree.entries.count == 0)

        let logs = try await repo.logs()
        #expect(logs.count == 2)
    }

    @Test("Commit revert")
    func commitRevert() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.initialize()
        try await repo.write("Some text", path: "Documents/foo.txt")
        let commit1_Hash = try await repo.commit("Initial commit")
        #expect(commit1_Hash.isEmpty == false)
        #expect(try await repo.objects.exists(key: .init(hash: commit1_Hash, kind: .commit)) == true)

        try await repo.write("Some edited text", path: "Documents/foo.txt")
        try await repo.write("Some text", path: "Documents/foo.txt")
        let status = try await repo.status()
        #expect(status.count == 0)
    }

    @Test("File References")
    func fileReferences() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.write("This is some foo", path: "foo.txt")
        try await repo.write("This is some bar", path: "Documents/bar.txt")

        let references = try await repo.retrieveCurrentBlobReferences()
        #expect(references.count == 2)

        let changes = try await repo.status()
        #expect(changes["foo.txt"] == .added)
        #expect(changes["Documents/bar.txt"] == .added)
    }

    @Test("Logs filtered by path")
    func logsWithPath() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.initialize()

        // Commit 1: add foo.txt
        try await CommitFile(repo, path: "foo.txt", content: "foo v1", message: "Add foo")

        // Commit 2: add bar.txt (foo unchanged)
        try await CommitFile(repo, path: "bar.txt", content: "bar v1", message: "Add bar")

        // Commit 3: modify foo.txt
        try await CommitFile(repo, path: "foo.txt", content: "foo v2", message: "Update foo")

        let allLogs = try await repo.logs()
        #expect(allLogs.count == 3)

        // Only commits 1 and 3 touched foo.txt
        let fooLogs = try await repo.logs(path: "foo.txt")
        #expect(fooLogs.count == 2)
        #expect(fooLogs[0].message == "Update foo")
        #expect(fooLogs[1].message == "Add foo")

        // Only commit 2 touched bar.txt
        let barLogs = try await repo.logs(path: "bar.txt")
        #expect(barLogs.count == 1)
        #expect(barLogs[0].message == "Add bar")
    }

    @Test("Logs filtered by nested path")
    func logsWithNestedPath() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.initialize()

        try await CommitFile(repo, path: "Documents/notes.txt", content: "v1", message: "Add notes")
        try await CommitFile(repo, path: "README.md", content: "hello", message: "Add readme")
        try await CommitFile(repo, path: "Documents/notes.txt", content: "v2", message: "Update notes")

        let notesLogs = try await repo.logs(path: "Documents/notes.txt")
        #expect(notesLogs.count == 2)
        #expect(notesLogs[0].message == "Update notes")
        #expect(notesLogs[1].message == "Add notes")

        let readmeLogs = try await repo.logs(path: "README.md")
        #expect(readmeLogs.count == 1)
        #expect(readmeLogs[0].message == "Add readme")
    }

    @Test("Logs for deleted file")
    func logsWithDeletedFile() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.initialize()

        try await CommitFile(repo, path: "temp.txt", content: "temporary", message: "Add temp")
        try await repo.delete("temp.txt")
        let _ = try await repo.commit("Delete temp")

        let tempLogs = try await repo.logs(path: "temp.txt")
        #expect(tempLogs.count == 2)
        #expect(tempLogs[0].message == "Delete temp")
        #expect(tempLogs[1].message == "Add temp")
    }

    @Test("Logs for nonexistent path")
    func logsWithNonexistentPath() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.initialize()
        try await CommitFile(repo, path: "foo.txt", content: "hello", message: "Add foo")

        let logs = try await repo.logs(path: "does/not/exist.txt")
        #expect(logs.isEmpty)
    }

    @Test("Tree optimization")
    func treeOptimizationTest() async throws {
        let (path, repo) = NewRepo()
        defer { RemoveDirectory(path) }

        try await repo.initialize()
        try await repo.write("This is some foo", path: "foo.txt")
        try await repo.write("This is some bar", path: "Documents/bar.txt")
        try await repo.write("This is some baz", path: "Documents/Sub/baz.txt")

        let commit1_Hash = try await repo.commit("Initial commit")
        let commit1 = try await repo.objects.retrieve(commit: commit1_Hash)
        let commit1_Tree = try await repo.objects.retrieve(tree: commit1.tree)
        let commit1_TreeBarEntry = commit1_Tree.entries.first { $0.name == "Documents" }
        let commit1_TreeBarEntryHash = commit1_TreeBarEntry?.hash

        try await repo.write("Updated foo", path: "foo.txt")

        let commit2_Hash = try await repo.commit("Update file")
        let commit2 = try await repo.objects.retrieve(commit: commit2_Hash)
        let commit2_Tree = try await repo.objects.retrieve(tree: commit2.tree)
        let commit2_TreeBarEntry = commit2_Tree.entries.first { $0.name == "Documents" }!
        let commit2_TreeBarEntryHash = commit2_TreeBarEntry.hash
        #expect(commit1_TreeBarEntryHash == commit2_TreeBarEntryHash, "'bar' directory tree should be reused")
        #expect(commit1.tree != commit2.tree, "root tree should be different")

        let commit1_FooEntry = commit1_Tree.entries.first { $0.name == "foo.txt" }!
        let commit2_FooEntry = commit2_Tree.entries.first { $0.name == "foo.txt" }!
        #expect(commit1_FooEntry.hash != commit2_FooEntry.hash, "'foo' directory tree should be different")
    }
}
