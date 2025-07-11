import Foundation
import CryptoKit
import Testing
@testable import Wit

@Suite("Remote Tests")
final class RemoteTests {

    @Test("Push")
    func push() async throws {
        try await client.write("This is some foo", path: "foo.txt")
        try await client.write("This is some bar", path: "bar.txt")
        let initialCommitHash = try await client.commit(
            message: "Initial commit",
            author: "Test User <test@example.com>"
        )
        let initialStatus = try await client.status(commitHash: initialCommitHash)
        #expect(initialStatus.hasChanges == false)

        // Push local commit to remote instance.
        try await client.push(remote: remote)
    }

    @Test("Fetch")
    func fetch() async throws {
        try await client.write("This is some foo", path: "foo.txt")
        try await client.write("This is some bar", path: "bar.txt")
        let firstCommitHash = try await client.commit(
            message: "First commit",
            author: "Test User <test@example.com>"
        )
        try await client.push(remote: remote)

        // Second commit
        try await client.write("This is some updated foo", path: "foo.txt")
        let secondCommitHash = try await client.commit(
            message: "Second commit",
            author: "Test User <test@example.com>",
            previousCommitHash: firstCommitHash
        )
        try await client.push(remote: remote)

        // Delete second commit
        let dir = String(secondCommitHash.prefix(2))
        let file = String(secondCommitHash.dropFirst(2))
        try await client.local.delete(path: "objects/\(dir)/\(file)", privateKey: privateKey)
        try await client.write(firstCommitHash, path: ".wild/HEAD")

        // Establish new empty client
        let newClient = Client(workingPath: workingPath, privateKey: privateKey)

        // Fetch remote files
        try await newClient.fetch(remote: remote)

        // HEAD should not have changed with fetch
        let head = try await newClient.read(".wild/HEAD")
        #expect(head == firstCommitHash)

        let files = try await newClient.tracked()
        #expect(files.count == 2)
    }

    @Test("Rebase")
    func rebase() async throws {

        // First commit
        try await client.write("This is some foo", path: "foo.txt")
        let firstCommitHash = try await client.commit(
            message: "First commit",
            author: "Test User <test@example.com>"
        )
        try await client.push(remote: remote)

        // Second commit
        try await client.write("This is some bar", path: "bar.txt")
        let secondCommitHash = try await client.commit(
            message: "Second commit",
            author: "Test User <test@example.com>",
            previousCommitHash: firstCommitHash
        )
        try await client.push(remote: remote)

        // Delete second commit locally and rollback HEAD
        let dir = String(secondCommitHash.prefix(2))
        let file = String(secondCommitHash.dropFirst(2))
        try await client.local.delete(path: "objects/\(dir)/\(file)", privateKey: privateKey)
        try await client.write(firstCommitHash, path: ".wild/HEAD")

        // Establish new client and rebase
        let newClient = Client(workingPath: workingPath, privateKey: privateKey)
        try await newClient.rebase(remote: remote)

        let head = try await newClient.read(".wild/HEAD")
        #expect(head != firstCommitHash)
        #expect(head != secondCommitHash)
    }

    @Test("Reset")
    func reset() async throws {
        try await client.write("This is some foo", path: "foo.txt")
        try await client.write("This is some bar", path: "bar.txt")
        let firstCommitHash = try await client.commit(
            message: "First commit",
            author: "Test User <test@example.com>"
        )
        try await client.push(remote: remote)

        // Second commit
        try await client.write("This is some updated foo", path: "foo.txt")
        let secondCommitHash = try await client.commit(
            message: "Second commit",
            author: "Test User <test@example.com>",
            previousCommitHash: firstCommitHash
        )
        try await client.push(remote: remote)

        // Delete second commit
        let dir = String(secondCommitHash.prefix(2))
        let file = String(secondCommitHash.dropFirst(2))
        try await client.local.delete(path: "objects/\(dir)/\(file)", privateKey: privateKey)
        try await client.write(firstCommitHash, path: ".wild/HEAD")

        // Establish new empty client
        let newClient = Client(workingPath: workingPath, privateKey: privateKey)
        try await newClient.reset(remote: remote)

        // HEAD should have changed with rebase
        let head = try await newClient.read(".wild/HEAD")
        #expect(head == secondCommitHash)

        let files = try await newClient.tracked()
        #expect(files.count == 2)
    }

    // MARK: Setup and Teardown

    let workingPath: String
    let privateKey: Remote.PrivateKey
    let client: Client
    let remote: Remote

    init() async throws {
        self.workingPath = UUID().uuidString
        self.privateKey = Remote.PrivateKey()
        self.client = Client(workingPath: workingPath, privateKey: privateKey)
        self.remote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080/\(workingPath)")!)

        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let remote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080")!)
        let data = """
            {"id": "\(workingPath)", "publicKey": "\(publicKey)"}
            """.data(using: .utf8)
        try await remote.put(path: "register", data: data!, mimetype: nil, privateKey: nil)
    }

    deinit { teardown() }

    func teardown() {
        try? FileManager.default.removeItem(at: .documentsDirectory/workingPath)
        let privateKey = privateKey
        let remote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080/\(workingPath)")!)
        Task { try await remote.put(path: "unregister", data: Data(), mimetype: nil, privateKey: privateKey) }
    }
}
