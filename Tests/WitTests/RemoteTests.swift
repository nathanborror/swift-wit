import Foundation
import CryptoKit
import Testing
@testable import Wit

@Suite("Remote Tests")
final class RemoteTests {

    @Test("Push")
    func push() async throws {
        try await client.write("This is some foo".data(using: .utf8), path: "foo.txt")
        try await client.write("This is some bar".data(using: .utf8), path: "bar.txt")
        let initialCommitHash = try await client.commit("Initial commit")
        let initialStatus = try await client.status(.commit(initialCommitHash))
        #expect(initialStatus.isEmpty)

        // Push local commit to remote instance.
        try await client.push(remote)
    }

    @Test("Fetch")
    func fetch() async throws {
        try await client.write("This is some foo".data(using: .utf8), path: "foo.txt")
        try await client.write("This is some bar".data(using: .utf8), path: "bar.txt")
        let firstCommitHash = try await client.commit("First commit")
        try await client.push(remote)

        // Second commit
        try await client.write("This is some updated foo".data(using: .utf8), path: "foo.txt")
        let secondCommitHash = try await client.commit("Second commit")
        try await client.push(remote)

        // Delete second commit
        let dir = String(secondCommitHash.prefix(2))
        let file = String(secondCommitHash.dropFirst(2))
        try await client.disk.delete(path: "objects/\(dir)/\(file)", privateKey: privateKey)
        try await client.write(firstCommitHash.data(using: .utf8), path: ".wild/HEAD")

        // Establish new empty client
        let newClient = Wit(url: .documentsDirectory/workingPath, privateKey: privateKey)

        // Fetch remote files
        try await newClient.fetch(remote)

        // HEAD should not have changed with fetch
        let head = await newClient.retrieveHEAD()
        #expect(head == firstCommitHash)

        // TODO: Check locally cached remote data
    }

    @Test("Rebase")
    func rebase() async throws {
        // First commit
        try await client.write("This is some foo".data(using: .utf8), path: "foo.txt")
        let firstCommitHash = try await client.commit("First commit")
        try await client.push(remote)

        // Second commit
        try await client.write("This is some bar".data(using: .utf8), path: "bar.txt")
        let secondCommitHash = try await client.commit("Second commit")
        try await client.push(remote)

        // Delete second commit locally and rollback HEAD
        let dir = String(secondCommitHash.prefix(2))
        let file = String(secondCommitHash.dropFirst(2))
        try await client.disk.delete(path: "objects/\(dir)/\(file)", privateKey: privateKey)
        try await client.write(firstCommitHash.data(using: .utf8), path: ".wild/HEAD")

        // Establish new client and rebase
        let newClient = Wit(url: .documentsDirectory/workingPath, privateKey: privateKey)
        try await newClient.rebase(remote)

        // TODO: Fix this
        //let head = await newClient.retrieveHEAD()
        //#expect(head != firstCommitHash)
        //#expect(head != secondCommitHash)
    }

    // MARK: Setup and Teardown

    let workingPath: String
    let privateKey: Remote.PrivateKey
    let client: Wit
    let remote: Remote

    init() async throws {
        self.workingPath = UUID().uuidString
        self.privateKey = Remote.PrivateKey()
        self.client = Wit(url: .documentsDirectory/workingPath, privateKey: privateKey)
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
