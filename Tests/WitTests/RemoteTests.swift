import Foundation
import CryptoKit
import Testing
@testable import Wit

let isServerRunning = true

@Suite("Remote Tests", .enabled(if: isServerRunning))
final class RemoteTests {
    let privateKey: Remote.PrivateKey
    let identity: String
    let remote: Remote

    let clientA_workingPath: String
    let clientA: Repo

    let clientB_workingPath: String
    let clientB: Repo

    init() async throws {
        self.privateKey = Remote.PrivateKey()
        self.identity = UUID().uuidString

        self.clientA_workingPath = "A-\(identity)"
        self.clientB_workingPath = "B-\(identity)"

        self.clientA = Repo(path: clientA_workingPath, privateKey: privateKey)
        self.remote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080/\(identity)")!)

        // Establish public key
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        // Initialize
        try await clientA.initialize()
        try await clientA.configMerge(
            path: Repo.defaultConfigPath,
            values: [
                "core": .dictionary([
                    "publicKey": publicKey
                ]),
                "user": .dictionary([
                    "id": identity,
                    "name": "Alice",
                    "email": "alice@example.com",
                    "username": "alice",
                ]),
            ]
        )

        // Register with remote HTTP server
        let registerRemote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080")!)
        let configData = try await clientA.read(Repo.defaultConfigPath)
        try await registerRemote.put(path: "registration", data: configData, directoryHint: .notDirectory, privateKey: nil)

        self.clientB = Repo(path: clientB_workingPath, privateKey: privateKey)
        try await self.clientB.initialize()
    }

    deinit { teardown() }

    func teardown() {
        try? FileManager.default.removeItem(at: .documentsDirectory/clientA_workingPath)
        try? FileManager.default.removeItem(at: .documentsDirectory/clientB_workingPath)
        let privateKey = privateKey
        let remote = RemoteHTTP(baseURL: .init(string: "http://localhost:8080/\(identity)")!)
        Task { try await remote.delete(path: "registration", privateKey: privateKey) }
    }

    @Test("Push")
    func push() async throws {
        try await clientA.write("This is some foo", path: "foo.txt")
        try await clientA.write("This is some bar", path: "bar.txt")
        try await clientA.commit("Initial commit")
        try await clientA.push(remote)

        let logCheck1 = try await clientA.logs()
        #expect(logCheck1.count == 1)

        try await clientA.write("This is more foo", path: "foo.txt")
        try await clientA.commit("Second commit")
        try await clientA.push(remote)

        let logCheck2 = try await clientA.logs()
        #expect(logCheck2.count == 2)
    }

    @Test("Rebase")
    func rebase() async throws {

        // ClientA: First commit
        try await clientA.write("This is some foo", path: "foo.txt")
        let clientA_commit1 = try await clientA.commit("First commit")
        try await clientA.push(remote)

        // ClientB: Clone
        try await clientB.clone(remote)
        let clientB_HEAD = await clientB.readHEAD()
        #expect(clientB_HEAD == clientA_commit1)

        // ClientA: Second commit
        try await clientA.write("This is some bar", path: "bar.txt")
        try await clientA.commit("Second commit")
        try await clientA.push(remote)
        let clientA_logs = try await clientA.logs()
        #expect(clientA_logs.count == 2)

        try await clientB.rebase(remote)
        let logs = try await clientB.logs()
        #expect(logs.count == 2)
    }

    @Test("Config parsing")
    func configParsing() async throws {
        let config = try await clientA.configRead(path: Repo.defaultConfigPath)
        #expect(config["core.version"] == "0.1")
    }
}
