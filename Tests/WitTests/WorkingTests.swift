import Foundation
import Testing
@testable import Wit

@Suite("Working Tests")
struct WorkingTests {
    let witURL = URL.documentsDirectory.appending(path: "wit-test/.wit")
    let workingURL = URL.documentsDirectory.appending(path: "wit-test")

    @Test("Basic commit workflow")
    func basicCommitWorkflow() async throws {
        let client = try Client(workingURL: workingURL)

        let doc = "This is my document"
        let docURL = workingURL.appending(path: "README.md")
        try doc.write(to: docURL, atomically: true, encoding: .utf8)

        let commitHash = try client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )
        #expect(commitHash.isEmpty == false)
        #expect(client.storage.exists(hash: commitHash))

        let commit = try client.storage.retrieve(commitHash, as: Commit.self)
        #expect(commit.message == "Initial commit")
        #expect(commit.parent.isEmpty)

        let tree = try client.storage.retrieve(commit.tree, as: Tree.self)
        #expect(tree.entries.count == 1)
        #expect(tree.entries[0].name == "README.md")

        let blob = try client.storage.retrieve(tree.entries[0].hash, as: Blob.self)
        #expect(blob.content.count > 0)
    }
}
