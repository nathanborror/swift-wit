import Foundation
import CryptoKit
import Testing
@testable import Wit

let isServerRunning = false

@Suite("Remote Tests", .enabled(if: isServerRunning))
final class RemoteTests {
    let workingPath: String
    let privateKey: Remote.PrivateKey
    let client: Repo
    let remote: Remote

    init() async throws {
        self.workingPath = UUID().uuidString
        self.privateKey = Remote.PrivateKey()
        self.client = Repo(path: workingPath, privateKey: privateKey)
        self.remote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080/\(workingPath)")!)

        // Establish public key
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        // Initialize
        try await client.initialize()
        try await client.configMerge(
            path: Repo.defaultConfigPath,
            values: [
                "core": .dictionary([
                    "publicKey": publicKey
                ]),
                "user": .dictionary([
                    "id": workingPath,
                    "name": "Alice",
                    "email": "alice@example.com",
                    "username": "alice",
                ]),
            ]
        )

        // Register with remote HTTP server
        let registerRemote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080")!)
        let configData = try await client.read(Repo.defaultConfigPath)
        try await registerRemote.put(path: "register", data: configData, directoryHint: .notDirectory, privateKey: nil)
    }

    deinit { teardown() }

    func teardown() {
        try? FileManager.default.removeItem(at: .documentsDirectory/workingPath)
        let privateKey = privateKey
        let remote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080/\(workingPath)")!)
        Task { try await remote.put(path: "unregister", data: Data(), directoryHint: .notDirectory, privateKey: privateKey) }
    }

    @Test("Push")
    func push() async throws {
        try await client.write("This is some foo", path: "foo.txt")
        try await client.write("This is some bar", path: "bar.txt")
        try await client.commit("Initial commit")
        try await client.push(remote)

        let logCheck1 = try await client.logs()
        #expect(logCheck1.count == 1)

        try await client.write("This is more foo", path: "foo.txt")
        try await client.commit("Second commit")
        try await client.push(remote)

        let logCheck2 = try await client.logs()
        #expect(logCheck2.count == 2)
    }

    @Test("Fetch")
    func fetch() async throws {
        try await client.write("This is some foo", path: "foo.txt")
        try await client.write("This is some bar", path: "bar.txt")
        let firstCommitHash = try await client.commit("First commit")
        try await client.push(remote)

        // Second commit
        try await client.write("This is some updated foo", path: "foo.txt")
        let secondCommitHash = try await client.commit("Second commit")
        try await client.push(remote)

        // Delete second commit
        let dir = String(secondCommitHash.prefix(2))
        let file = String(secondCommitHash.dropFirst(2))
        try await client.disk.delete(path: "objects/\(dir)/\(file)", privateKey: privateKey)
        try await client.write(firstCommitHash, path: ".wild/HEAD")

        // Establish new empty client
        let newClient = Repo(path: workingPath, privateKey: privateKey)

        // Fetch remote files
        try await newClient.fetch(remote)

        // HEAD should not have changed with fetch
        let head = await newClient.HEAD()
        #expect(head == firstCommitHash)

        // TODO: Check locally cached remote data
    }

    @Test("Rebase")
    func rebase() async throws {
        // First commit
        try await client.write("This is some foo", path: "foo.txt")
        let firstCommitHash = try await client.commit("First commit")
        try await client.push(remote)

        // Second commit
        try await client.write("This is some bar", path: "bar.txt")
        let secondCommitHash = try await client.commit("Second commit")
        try await client.push(remote)

        // Delete second commit locally and rollback HEAD
        let dir = String(secondCommitHash.prefix(2))
        let file = String(secondCommitHash.dropFirst(2))
        try await client.disk.delete(path: "objects/\(dir)/\(file)", privateKey: privateKey)
        try await client.write(firstCommitHash, path: ".wild/HEAD")

        // Establish new client and rebase
        let newClient = Repo(path: workingPath, privateKey: privateKey)
        let _ = try await newClient.rebase(remote)

        let head = await newClient.HEAD()
        //#expect(head != firstCommitHash) TODO: Fix this
        #expect(head != secondCommitHash)
    }

    @Test("Config parsing")
    func configParsing() async throws {
        let config = try await client.configRead(path: Repo.defaultConfigPath)
        #expect(config["core.version"] == "1.0")
    }
}
