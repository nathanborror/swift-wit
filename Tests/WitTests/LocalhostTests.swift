import Foundation
import CryptoKit
import Testing
@testable import Wit

@Suite("Localhost Tests")
struct LocalhostTests {

    @Test("Push")
    func push() async throws {

        // Configure a client and write our first commit locally.
        let client = try Client()
        try await client.register()

        // Write some data to files
        try client.write("This is some foo", to: "foo.txt")
        try client.write("This is some bar", to: "bar.txt")
        let initialCommitHash = try client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )
        let initialStatus = try client.status(commitHash: initialCommitHash)
        #expect(initialStatus.hasChanges == false)

        // Push local commit to remote instance.
        try await client.push()

        // Cleanup.
        try await client.unregister()
    }

    @Test("Fetch")
    func fetch() async throws {
        let client = try Client()
        let (userID, privateKey) = try await client.register()

        // First commit
        try client.write("This is some foo", to: "foo.txt")
        try client.write("This is some bar", to: "bar.txt")
        let firstCommitHash = try client.commit(
            message: "First commit",
            author: "Test User <test@example.com>"
        )
        try await client.push()

        // Second commit
        try client.write("This is some updated foo", to: "foo.txt")
        let secondCommitHash = try client.commit(
            message: "Second commit",
            author: "Test User <test@example.com>"
        )
        try await client.push()

        // Delete second commit
        let commitHashURL = client.localStorage!.hashURL(secondCommitHash)
        try FileManager.default.removeItem(at: commitHashURL)
        try client.write(firstCommitHash, to: ".wild/HEAD")

        // Establish new empty client
        let newClient = try Client()
        try await newClient.register(userID: userID, privateKey: privateKey)
        try await newClient.fetch()

        // HEAD should not have changed with fetch
        let head = newClient.read(".wild/HEAD")
        #expect(head == firstCommitHash)

        let files = try newClient.tracked()
        #expect(files.count == 2)
    }

    @Test("Rebase")
    func rebase() async throws {
        let client = try Client()
        let (userID, privateKey) = try await client.register()

        // First commit
        try client.write("This is some foo", to: "foo.txt")
        try client.write("This is some bar", to: "bar.txt")
        let firstCommitHash = try client.commit(
            message: "First commit",
            author: "Test User <test@example.com>"
        )
        try await client.push()

        // Second commit
        try client.write("This is some updated foo", to: "foo.txt")
        let secondCommitHash = try client.commit(
            message: "Second commit",
            author: "Test User <test@example.com>"
        )
        try await client.push()

        // Delete second commit
        let commitHashURL = client.localStorage!.hashURL(secondCommitHash)
        try FileManager.default.removeItem(at: commitHashURL)
        try client.write(firstCommitHash, to: ".wild/HEAD")

        // Establish new empty client
        let newClient = try Client()
        try await newClient.register(userID: userID, privateKey: privateKey)
        try await newClient.rebase()

        // HEAD should have changed with rebase
        let head = newClient.read(".wild/HEAD")
        #expect(head == secondCommitHash)

        let files = try newClient.tracked()
        #expect(files.count == 2)
    }
}
