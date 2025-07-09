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

//    @Test("Fetch")
//    func fetch() async throws {
//        let client = try Client()
//        let (userID, privateKey) = try await client.register()
//
//        try client.write("This is some foo", to: "foo.txt")
//        try client.write("This is some bar", to: "bar.txt")
//        let initialCommitHash = try client.commit(
//            message: "Initial commit",
//            author: "Test User <test@example.com>"
//        )
//        try await client.push()
//
//        // Delete local files
//        try client.delete("")
//
//        // Establish new empty client
//        let newClient = try Client()
//        try await newClient.register(userID: userID, privateKey: privateKey)
//        try await newClient.fetch()
//
//        let head = newClient.read(".wild/HEAD")
//        #expect(head == initialCommitHash)
//
//        let files = try newClient.tracked()
//        #expect(files.count == 0)
//    }
}
